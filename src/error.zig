pub const AppError = error{
    InvalidArguments,
    DependencyUnavailable,
    InvalidMedia,
    DecodeFailed,
    ModelUnavailable,
    ModelVerificationFailed,
    InferenceFailed,
};
