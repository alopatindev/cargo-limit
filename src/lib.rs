//! **Documentation is [here](https://github.com/alopatindev/cargo-limit#readme).**

#[doc(hidden)]
pub mod models;

mod cargo_toml;
mod io;
mod messages;
mod options;
mod process;

#[doc(hidden)]
pub use process::NO_EXIT_CODE;

use anyhow::{Context, Result};
use cargo_metadata::{Message, MetadataCommand};
use io::Buffers;
use messages::{ParsedMessages, ProcessedMessages};
use models::{EditorData, SourceFile};
use options::Options;
use process::{failed_to_execute_error_text, CargoProcess};
use std::{
    io::Write,
    path::Path,
    process::{Command, Stdio},
};

const ADDITIONAL_ENVIRONMENT_VARIABLES: &str =
    include_str!("../additional_environment_variables.txt");

#[doc(hidden)]
pub fn run_cargo_filtered(current_exe: String) -> Result<i32> {
    let workspace_root = MetadataCommand::new().no_deps().exec()?.workspace_root;
    let workspace_root = workspace_root.as_ref();
    let parsed_args = Options::from_os_env(current_exe, workspace_root)?;
    // TODO: args => options?

    let mut cargo_process = CargoProcess::run(&parsed_args)?;

    let mut buffers = Buffers::new(cargo_process.child_mut())?;
    let mut parsed_messages =
        parse_messages_with_timeout(&mut buffers, Some(&cargo_process), &parsed_args)?;

    let exit_code = if parsed_messages.child_killed {
        buffers.writeln_to_stdout("")?;
        let exit_code = cargo_process.wait()?;
        parsed_messages.merge(parse_messages_with_timeout(
            &mut buffers,
            None,
            &parsed_args,
        )?);
        process_messages(&mut buffers, parsed_messages, &parsed_args, workspace_root)?;
        buffers.copy_from_child_stdout_reader_to_stdout_writer()?;

        exit_code
    } else {
        process_messages(&mut buffers, parsed_messages, &parsed_args, workspace_root)?;
        buffers.copy_from_child_stdout_reader_to_stdout_writer()?;
        cargo_process.wait()?
    };

    if parsed_args.help {
        buffers.write_to_stdout(ADDITIONAL_ENVIRONMENT_VARIABLES)?;
    }

    Ok(exit_code)
}

fn parse_messages_with_timeout(
    buffers: &mut Buffers,
    cargo_process: Option<&CargoProcess>,
    parsed_args: &Options,
) -> Result<ParsedMessages> {
    if parsed_args.help || parsed_args.version {
        Ok(ParsedMessages::default())
    } else {
        ParsedMessages::parse_with_timeout(
            buffers.child_stdout_reader_mut(),
            cargo_process,
            parsed_args,
        )
    }
}

fn process_messages(
    buffers: &mut Buffers,
    parsed_messages: ParsedMessages,
    parsed_args: &Options,
    workspace_root: &Path,
) -> Result<()> {
    let ProcessedMessages {
        messages,
        source_files_in_consistent_order,
    } = ProcessedMessages::process(parsed_messages, &parsed_args, workspace_root)?;
    let processed_messages = messages.into_iter();

    if parsed_args.json_message_format {
        for message in processed_messages {
            buffers.writeln_to_stdout(&serde_json::to_string(&message)?)?;
        }
    } else {
        for message in processed_messages.filter_map(|message| match message {
            Message::CompilerMessage(compiler_message) => compiler_message.message.rendered,
            _ => None,
        }) {
            buffers.write_to_stderr(message)?;
        }
    }

    open_in_external_app_for_affected_files(
        buffers,
        source_files_in_consistent_order,
        parsed_args,
        workspace_root,
    )
}

fn open_in_external_app_for_affected_files(
    buffers: &mut Buffers,
    source_files_in_consistent_order: Vec<SourceFile>,
    parsed_args: &Options,
    workspace_root: &Path,
) -> Result<()> {
    let app = &parsed_args.open_in_external_app;
    if !app.is_empty() {
        let editor_data = EditorData::new(workspace_root, source_files_in_consistent_order);
        let mut child = Command::new(app).stdin(Stdio::piped()).spawn()?;
        child
            .stdin
            .take()
            .context("no stdin")?
            .write_all(serde_json::to_string(&editor_data)?.as_bytes())?;

        let error_text = failed_to_execute_error_text(app);
        let output = child.wait_with_output().context(error_text)?;

        buffers.write_all_to_stderr(&output.stdout)?;
        buffers.write_all_to_stderr(&output.stderr)?;
    }
    Ok(())
}

#[doc(hidden)]
#[macro_export]
macro_rules! run_subcommand {
    () => {
        #[doc(hidden)]
        fn main() -> anyhow::Result<()> {
            use anyhow::Context;
            let current_exe = std::env::current_exe()?
                .file_stem()
                .context("invalid executable")?
                .to_string_lossy()
                .to_string();
            std::process::exit(cargo_limit::run_cargo_filtered(current_exe)?);
        }
    };
}
