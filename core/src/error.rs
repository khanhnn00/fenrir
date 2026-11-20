#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FenrirError {
    #[error("invalid project: {0}")]
    Invalid(String),
    #[error("database error: {0}")]
    Db(String),
    #[error("session error: {0}")]
    Session(String),
    #[error("{0}")]
    Network(String),
}

impl From<rusqlite::Error> for FenrirError {
    fn from(e: rusqlite::Error) -> Self {
        FenrirError::Db(e.to_string())
    }
}

impl FenrirError {
    /// The text without the variant's prefix.
    pub fn message(&self) -> &str {
        match self {
            FenrirError::Invalid(m) | FenrirError::Db(m) | FenrirError::Session(m) | FenrirError::Network(m) => m,
        }
    }
}
