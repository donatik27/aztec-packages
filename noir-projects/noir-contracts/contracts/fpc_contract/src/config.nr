use dep::aztec::protocol_types::{address::AztecAddress, traits::{Deserialize, Serialize}};

global CONFIG_LENGTH: u32 = 2;

pub struct Config {
    pub accepted_asset: AztecAddress, // Asset the FPC accepts (denoted as AA below)
    pub admin: AztecAddress, // Address to which AA is sent during the private fee payment flow
}

impl Serialize<CONFIG_LENGTH> for Config {
    fn serialize(self: Self) -> [Field; CONFIG_LENGTH] {
        [self.accepted_asset.to_field(), self.admin.to_field()]
    }
}

impl Deserialize<CONFIG_LENGTH> for Config {
    fn deserialize(fields: [Field; CONFIG_LENGTH]) -> Self {
        Config {
            accepted_asset: AztecAddress::from_field(fields[0]),
            admin: AztecAddress::from_field(fields[1]),
        }
    }
}
