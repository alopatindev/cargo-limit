use crate::{io::Buffers, models::SourceFile, options::Options, process};
use anyhow::Result;
use cargo_metadata::{
    diagnostic::{DiagnosticLevel, DiagnosticSpan},
    CompilerMessage, Message,
};
use getset::CopyGetters;
use itertools::{Either, Itertools};
use process::CargoProcess;
use std::{collections::HashSet, path::Path, time::Duration};

#[derive(Default, CopyGetters, Debug)]
pub struct Messages {
    internal_compiler_errors: Vec<CompilerMessage>,
    errors: Vec<CompilerMessage>,
    non_errors: Vec<CompilerMessage>,

    #[get_copy = "pub"]
    child_killed: bool,
}

struct FilteredAndOrderedMessages {
    errors: Vec<CompilerMessage>,
    warnings: Vec<CompilerMessage>,
}

struct TransformedMessages {
    messages: Vec<Message>,
    source_files_in_consistent_order: Vec<SourceFile>,
}

pub fn transform_and_process_messages(
    buffers: &mut Buffers,
    messages: Messages,
    options: &Options,
    workspace_root: &Path,
    mut process: impl FnMut(&mut Buffers, Vec<Message>, Vec<SourceFile>) -> Result<()>,
) -> Result<()> {
    let TransformedMessages {
        messages,
        source_files_in_consistent_order,
    } = TransformedMessages::transform(messages, options, workspace_root)?;
    process(buffers, messages, source_files_in_consistent_order)
}

impl Messages {
    pub fn parse_with_timeout_on_error(
        buffers: &mut Buffers,
        cargo_process: Option<&CargoProcess>,
        options: &Options,
    ) -> Result<Self> {
        let mut result = Messages::default();
        if options.help() || options.version() {
            return Ok(result);
        }

        for message in Message::parse_stream(buffers.child_stdout_reader_mut()) {
            match message? {
                Message::CompilerMessage(compiler_message) => {
                    match compiler_message.message.level {
                        DiagnosticLevel::Ice => {
                            result.internal_compiler_errors.push(compiler_message)
                        },
                        DiagnosticLevel::Error => result.errors.push(compiler_message),
                        _ => result.non_errors.push(compiler_message),
                    }
                },
                Message::BuildFinished(_) => {
                    break;
                },
                _ => (),
            }

            if let Some(cargo_process) = cargo_process {
                if result.has_errors() {
                    let time_limit = options.time_limit_after_error();
                    if time_limit > Duration::from_secs(0) {
                        cargo_process.kill_after_timeout(time_limit);
                    }
                }
            }
        }

        result.child_killed = if let Some(cargo_process) = cargo_process {
            cargo_process.wait_if_killing_is_in_progress() == process::State::NotRunning
        } else {
            false
        };

        Ok(result)
    }

    pub fn merge(&mut self, other: Self) {
        self.internal_compiler_errors
            .extend(other.internal_compiler_errors);
        self.errors.extend(other.errors);
        self.non_errors.extend(other.non_errors);
        self.child_killed |= other.child_killed;
    }

    fn has_errors(&self) -> bool {
        !self.errors.is_empty() || !self.internal_compiler_errors.is_empty()
    }
}

impl FilteredAndOrderedMessages {
    fn filter(messages: Messages, options: &Options, workspace_root: &Path) -> Self {
        let non_errors = messages.non_errors.into_iter();
        let warnings = if options.show_dependencies_warnings() {
            Either::Left(non_errors)
        } else {
            Either::Right(non_errors.filter(|i| i.target.src_path.starts_with(workspace_root)))
        };
        let warnings = Self::filter_and_order_messages(warnings, workspace_root);

        let cargo_errors = Self::filter_cargo_errors(&messages.errors);
        let errors = messages
            .internal_compiler_errors
            .into_iter()
            .chain(messages.errors);
        let errors = Self::filter_and_order_messages(errors, workspace_root);
        let errors = if errors.is_empty() {
            cargo_errors
        } else {
            errors
        };

        Self { errors, warnings }
    }

    fn filter_cargo_errors(messages: &[CompilerMessage]) -> Vec<CompilerMessage> {
        let (good, bad): (Vec<_>, Vec<_>) = messages
            .iter()
            .filter_map(|i| {
                if i.message.spans.is_empty() && i.message.rendered.is_some() {
                    let i = i.clone();
                    let item = if i.message.message.contains("aborting due to previous error") {
                        (None, Some(i))
                    } else {
                        (Some(i), None)
                    };
                    Some(item)
                } else {
                    None
                }
            })
            .unzip();

        let filter = |items: Vec<Option<CompilerMessage>>| -> Vec<CompilerMessage> {
            items
                .into_iter()
                .flatten()
                .unique_by(|i| i.message.rendered.clone())
                .collect()
        };
        let good = filter(good);
        let bad = filter(bad);

        if good.is_empty() {
            bad
        } else {
            good
        }
    }

    fn filter_and_order_messages(
        messages: impl IntoIterator<Item = CompilerMessage>,
        workspace_root: &Path,
    ) -> Vec<CompilerMessage> {
        let messages = messages
            .into_iter()
            .unique()
            .filter(|i| !i.message.spans.is_empty())
            .map(|i| {
                let spans_from_leaf_to_root = i.message.spans.iter().rev();
                let key = spans_from_leaf_to_root
                    .map(|span| (span.file_name.clone(), span.line_start))
                    .collect::<Vec<_>>();
                (key, i)
            })
            .into_group_map()
            .into_iter()
            .sorted_by_key(|(paths, _messages)| paths.clone())
            .flat_map(|(_paths, messages)| messages);

        let mut project_messages = Vec::new();
        let mut dependencies_messages = Vec::new();
        for i in messages {
            if i.target.src_path.starts_with(workspace_root) {
                project_messages.push(i);
            } else {
                dependencies_messages.push(i);
            }
        }

        project_messages
            .into_iter()
            .chain(dependencies_messages)
            .collect()
    }
}

impl TransformedMessages {
    fn transform(
        messages: Messages,
        options: &Options,
        workspace_root: &Path,
    ) -> Result<TransformedMessages> {
        let FilteredAndOrderedMessages { errors, warnings } =
            FilteredAndOrderedMessages::filter(messages, options, workspace_root);
        let has_errors = !errors.is_empty();

        let errors = errors.into_iter();
        let warnings = warnings.into_iter();
        let messages = if options.show_warnings_if_errors_exist() {
            Either::Left(errors.chain(warnings))
        } else {
            let messages = if has_errors {
                Either::Left(errors)
            } else {
                Either::Right(warnings)
            };
            Either::Right(messages)
        };

        let limit_messages = options.limit_messages();
        let no_limit = limit_messages == 0;
        let messages = {
            if no_limit {
                Either::Left(messages)
            } else {
                Either::Right(messages.take(limit_messages))
            }
        }
        .collect::<Vec<_>>();

        let source_files_in_consistent_order =
            Self::extract_source_files_for_external_app(&messages, options, workspace_root);

        let messages = messages.into_iter();
        let messages = {
            if options.ascending_messages_order() {
                Either::Left(messages)
            } else {
                Either::Right(messages.rev())
            }
        }
        .map(Message::CompilerMessage)
        .collect();

        Ok(TransformedMessages {
            messages,
            source_files_in_consistent_order,
        })
    }

    fn extract_source_files_for_external_app(
        messages: &[CompilerMessage],
        options: &Options,
        workspace_root: &Path,
    ) -> Vec<SourceFile> {
        let spans_and_messages = messages
            .iter()
            .filter(|message| {
                if options.open_in_external_app_on_warnings() {
                    true
                } else {
                    matches!(
                        message.message.level,
                        DiagnosticLevel::Error | DiagnosticLevel::Ice
                    )
                }
            })
            .flat_map(|message| {
                message
                    .message
                    .spans
                    .iter()
                    .filter(|span| span.is_primary)
                    .cloned()
                    .map(move |span| (span, message))
            })
            .map(|(span, message)| (Self::find_leaf_project_expansion(span), &message.message));

        // FIXME: if line contains error and warning we may drop
        // error and leave warning, which will be dropped later
        // as well (if we run llcheck)?

        let mut source_files_in_consistent_order = Vec::new();
        let mut used_file_names_and_lines = HashSet::new();
        for (span, message) in spans_and_messages {
            let file_name = span.file_name.clone();
            if !used_file_names_and_lines.contains(&(file_name.clone(), span.line_start)) {
                used_file_names_and_lines.insert((file_name, span.line_start));
                source_files_in_consistent_order.push(SourceFile::new(
                    span,
                    message,
                    workspace_root,
                ));
            }
        }

        source_files_in_consistent_order
    }

    fn find_leaf_project_expansion(mut span: DiagnosticSpan) -> DiagnosticSpan {
        let mut project_span = span.clone();
        while let Some(expansion) = span.expansion {
            span = expansion.span;
            if Path::new(&span.file_name).is_relative() {
                project_span = span.clone();
            }
        }
        project_span
    }
}
