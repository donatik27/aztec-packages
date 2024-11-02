use strum::AsRefStr;

/// All AVM opcodes
/// Keep updated with TS, cpp, and docs protocol specs!
#[allow(clippy::upper_case_acronyms, dead_code, non_camel_case_types)]
#[derive(PartialEq, Copy, Clone, Debug, Eq, Hash, AsRefStr)]
#[strum(serialize_all = "SCREAMING_SNAKE_CASE")]
pub enum AvmOpcode {
    /// Arithmetic operations
    ADD_8,
    ADD_16,
    SUB_8,
    SUB_16,
    MUL_8,
    MUL_16,
    DIV_8,
    DIV_16,
    FDIV_8,
    FDIV_16,

    /// Comparison operations
    EQ_8,
    EQ_16,
    LT_8,
    LT_16,
    LTE_8,
    LTE_16,

    /// Bitwise operations
    AND_8,
    AND_16,
    OR_8,
    OR_16,
    XOR_8,
    XOR_16,
    NOT_8,
    NOT_16,
    SHL_8,
    SHL_16,
    SHR_8,
    SHR_16,

    /// Type conversions
    CAST_8,
    CAST_16,

    // ... rest of the enum variants stay the same ...
}

impl AvmOpcode {
    pub fn name(&self) -> &'static str {
        // The strum::AsRefStr derive macro automatically implements this
        self.as_ref()
    }
}
