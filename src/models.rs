use cargo_metadata::diagnostic::{Diagnostic, DiagnosticLevel, DiagnosticSpan};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Deserialize, Serialize)]
pub struct EditorData {
    protocol_version: String,
    workspace_root: PathBuf,
    locations: Vec<Location>,
}

#[derive(Deserialize, Serialize)]
pub struct Location {
    path: PathBuf,
    line: usize,
    column: usize,
    message: String,
    level: DiagnosticLevel,
}

impl EditorData {
    pub fn new(workspace_root: &Path, locations_in_consistent_order: Vec<Location>) -> Self {
        let workspace_root = workspace_root.to_path_buf();
        let protocol_version = std::env!("CARGO_PKG_VERSION").to_string();
        Self {
            protocol_version,
            workspace_root,
            locations: locations_in_consistent_order,
        }
    }

    pub fn escaped_workspace_root(&self) -> String {
        const ESCAPE_CHAR: &str = "%";
        self.workspace_root
            .to_string_lossy()
            .replace(['/', '\\', ':'], ESCAPE_CHAR)
    }
}

impl Location {
    pub fn new(span: DiagnosticSpan, diagnostic: &Diagnostic, workspace_root: &Path) -> Self {
        let path = PathBuf::from(span.file_name);
        let path = if path.is_relative() {
            workspace_root.join(&path)
        } else {
            path
        };
        Self {
            path,
            line: span.line_start,
            column: span.column_start,
            message: diagnostic.message.clone(),
            level: diagnostic.level,
        }
    }
}
