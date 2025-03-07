use dep::protocol_types::{
    address::AztecAddress, constants::PRIVATE_LOG_SIZE_IN_FIELDS, hash::poseidon2_hash,
    point::Point, public_keys::AddressPoint, scalar::Scalar, utils::arrays::array_concat,
};
use std::{
    aes128::aes128_encrypt, embedded_curve_ops::fixed_base_scalar_mul as derive_public_key,
    hash::from_field_unsafe as fr_to_fq_unsafe,
};

use crate::{
    encrypted_logs::header::EncryptedLogHeader,
    keys::secret_derivation::derive_aes_secret,
    oracle::{
        notes::{get_app_tag_as_sender, increment_app_tagging_secret_index_as_sender},
        random::random,
    },
    utils::{bytes::bytes_to_fields, point::point_to_bytes},
};

// 1 field is reserved for tag.
global ENCRYPTED_PAYLOAD_SIZE_IN_BYTES: u32 = (PRIVATE_LOG_SIZE_IN_FIELDS - 1) * 31;

comptime global HEADER_SIZE: u32 = 48;

// Bytes padded to the overhead, so that the size of the incoming body ciphertext will be a multiple of 16.
comptime global OVERHEAD_PADDING: u32 = 15;

pub comptime global OVERHEAD_SIZE: u32 = 32 /* eph_pk */
    + HEADER_SIZE /* incoming_header */
    + OVERHEAD_PADDING /* padding */;

global PLAINTEXT_LENGTH_SIZE: u32 = 2;

// This is enough for 8 fields of data.
// 1 field for storage slot, 1 field for note/event type id, allowing 6 fields for custom values.
global MAX_PRIVATE_LOG_PLAINTEXT_SIZE_IN_BYTES: u32 =
    ENCRYPTED_PAYLOAD_SIZE_IN_BYTES - OVERHEAD_SIZE - PLAINTEXT_LENGTH_SIZE - 1 /* aes padding */;

// Note: Might have to update PRIVATE_LOG_SIZE_IN_FIELDS in `constants.nr` if the above changes.
// This value ideally should be set by the protocol, allowing users (or `aztec-nr`) to fit data within the defined size limits.
// Currently, we adjust this value as the structure changes, then update `constants.nr` to match.
// Once the structure is finalized with defined overhead and max note field sizes, this value will be fixed and should remain unaffected by further payload composition changes.

pub fn compute_private_log_payload<let P: u32>(
    contract_address: AztecAddress,
    recipient: AztecAddress,
    sender: AztecAddress,
    plaintext: [u8; P],
) -> [Field; PRIVATE_LOG_SIZE_IN_FIELDS] {
    assert(
        P < MAX_PRIVATE_LOG_PLAINTEXT_SIZE_IN_BYTES,
        f"plaintext for log must not exceed {MAX_PRIVATE_LOG_PLAINTEXT_SIZE_IN_BYTES}",
    );

    let extended_plaintext: [u8; MAX_PRIVATE_LOG_PLAINTEXT_SIZE_IN_BYTES + PLAINTEXT_LENGTH_SIZE] =
        extend_private_log_plaintext(plaintext);
    let encrypted: [u8; ENCRYPTED_PAYLOAD_SIZE_IN_BYTES] =
        compute_encrypted_log(contract_address, recipient, extended_plaintext);

    /// Safety: We assume that the sender wants for the recipient to find the tagged note, and therefore that they
    /// will cooperate and use the correct tag. Usage of a bad tag will result in the recipient not being able to
    /// find the note automatically.
    let tag = unsafe { get_app_tag_as_sender(sender, recipient) };
    increment_app_tagging_secret_index_as_sender(sender, recipient);

    array_concat([tag], bytes_to_fields(encrypted))
}

// We return [Field; 1 + (M + 30) / 31], where M is the byte length of output of encryption because
// each field (apart from the tag) contains 31 bytes so the length in fields is computed as ceil(setup_log_byte_length / 31)
// --> we achieve rounding by adding 30 and then dividing without remainder, then add one for the 32 byte tag
pub fn compute_partial_public_log_payload<let P: u32, let M: u32>(
    contract_address: AztecAddress,
    recipient: AztecAddress,
    sender: AztecAddress,
    plaintext: [u8; P],
) -> [Field; 1 + (M + 30) / 31] {
    let extended_plaintext: [u8; P + PLAINTEXT_LENGTH_SIZE] =
        extend_private_log_plaintext(plaintext);
    let encrypted: [u8; M] = compute_encrypted_log(contract_address, recipient, extended_plaintext);

    /// Safety: We assume that the sender wants for the recipient to find the tagged note, and therefore that they
    /// will cooperate and use the correct tag. Usage of a bad tag will result in the recipient not being able to
    /// find the note automatically.
    let tag = unsafe { get_app_tag_as_sender(sender, recipient) };
    increment_app_tagging_secret_index_as_sender(sender, recipient);
    // Silo the tag with contract address.
    // This is done by the kernel circuit to the private logs, but since the partial log will be finalized and emitted
    // in public as unencrypted log, its tag is not siloed at the moment.
    // To avoid querying logs using two types of tags, we silo the tag manually here.
    let siloed_tag = poseidon2_hash([contract_address.to_field(), tag]);

    array_concat([siloed_tag], bytes_to_fields(encrypted))
}

fn compute_encrypted_log<let P: u32, let M: u32>(
    contract_address: AztecAddress,
    recipient: AztecAddress,
    plaintext: [u8; P],
) -> [u8; M] {
    let (eph_sk, eph_pk) = generate_ephemeral_key_pair();

    let header = EncryptedLogHeader::new(contract_address);

    let incoming_header_ciphertext: [u8; HEADER_SIZE] =
        header.compute_ciphertext(eph_sk, recipient.to_address_point());
    let incoming_body_ciphertext =
        compute_incoming_body_ciphertext(plaintext, eph_sk, recipient.to_address_point());

    let mut encrypted_bytes = [0; M];
    let mut offset = 0;

    // eph_pk
    let eph_pk_bytes = point_to_bytes(eph_pk);
    for i in 0..32 {
        encrypted_bytes[offset + i] = eph_pk_bytes[i];
    }
    offset += 32;

    // incoming_header
    for i in 0..HEADER_SIZE {
        encrypted_bytes[offset + i] = incoming_header_ciphertext[i];
    }
    offset += HEADER_SIZE;

    // Padding.
    offset += OVERHEAD_PADDING;

    // incoming_body
    // Then we fill in the rest as the incoming body ciphertext
    let size = M - offset;
    assert_eq(size, incoming_body_ciphertext.len(), "ciphertext length mismatch");
    // Nargo seems to struggle with realizing that `offset` is a constant at this point.
    // We then redefine it in terms of the assertion above to give nargo a hint.
    let offset = M - incoming_body_ciphertext.len();
    for i in 0..size {
        encrypted_bytes[offset + i] = incoming_body_ciphertext[i];
    }

    encrypted_bytes
}

// Prepend the plaintext length as the first byte, then copy the plaintext itself starting from the second byte.
// Fill the remaining bytes with random values to reach a fixed length of N.
fn extend_private_log_plaintext<let P: u32, let N: u32>(plaintext: [u8; P]) -> [u8; N] {
    /// Safety: A malicious sender could reveal the whole contents of the encrypted log so trusting it to set
    /// a random padding in plaintext is fine.
    let mut padded = unsafe { get_random_bytes() };
    padded[0] = (P >> 8) as u8;
    padded[1] = P as u8;
    for i in 0..P {
        padded[i + PLAINTEXT_LENGTH_SIZE] = plaintext[i];
    }
    padded
}

unconstrained fn get_random_bytes<let N: u32>() -> [u8; N] {
    let mut bytes = [0; N];
    let mut idx = 32;
    let mut randomness = [0; 32];
    for i in 0..N {
        if idx == 32 {
            randomness = random().to_be_bytes();
            idx = 1; // Skip the first byte as it's always 0.
        }
        bytes[i] = randomness[idx];
        idx += 1;
    }
    bytes
}

fn generate_ephemeral_key_pair() -> (Scalar, Point) {
    // @todo Need to draw randomness from the full domain of Fq not only Fr

    /// Safety: We use the randomness to preserve the privacy of both the sender and recipient via encryption, so
    /// a malicious sender could use non-random values to reveal the plaintext. But they already know it themselves
    /// anyway, and so the recipient already trusts them to not disclose this information. We can therefore assume
    /// that the sender will cooperate in the random value generation.
    let randomness = unsafe { random() };

    // We use the unsafe version of `fr_to_fq` because multi_scalar_mul (called by derive_public_key) will constrain
    // the scalars.
    let eph_sk = fr_to_fq_unsafe(randomness);
    let eph_pk = derive_public_key(eph_sk);

    (eph_sk, eph_pk)
}

pub fn compute_incoming_body_ciphertext<let P: u32>(
    plaintext: [u8; P],
    eph_sk: Scalar,
    address_point: AddressPoint,
) -> [u8; P + 16 - P % 16] {
    let full_key = derive_aes_secret(eph_sk, address_point.to_point());
    let mut sym_key = [0; 16];
    let mut iv = [0; 16];

    for i in 0..16 {
        sym_key[i] = full_key[i];
        iv[i] = full_key[i + 16];
    }
    aes128_encrypt(plaintext, iv, sym_key)
}

mod test {
    use crate::encrypted_logs::payload::{
        compute_incoming_body_ciphertext, compute_private_log_payload,
        MAX_PRIVATE_LOG_PLAINTEXT_SIZE_IN_BYTES,
    };
    use dep::protocol_types::{address::AztecAddress, point::Point, scalar::Scalar};
    use protocol_types::public_keys::AddressPoint;
    use std::test::OracleMock;

    #[test]
    unconstrained fn test_encrypted_log_matches_typescript() {
        // All the values in this test were copied over from `encrypted_log_payload.test.ts`
        let contract_address = AztecAddress::from_field(
            0x10f48cd9eff7ae5b209c557c70de2e657ee79166868676b787e9417e19260e04,
        );

        let plaintext = [
            0, 0, 0, 1, 48, 22, 64, 206, 234, 117, 131, 145, 178, 225, 97, 201, 44, 5, 19, 241, 41,
            2, 15, 65, 37, 37, 106, 253, 174, 38, 70, 206, 49, 9, 159, 92, 16, 244, 140, 217, 239,
            247, 174, 91, 32, 156, 85, 124, 112, 222, 46, 101, 126, 231, 145, 102, 134, 134, 118,
            183, 135, 233, 65, 126, 25, 38, 14, 4, 15, 228, 107, 229, 131, 183, 31, 74, 181, 183,
            12, 38, 87, 255, 29, 5, 204, 207, 29, 41, 42, 147, 105, 98, 141, 26, 25, 79, 148, 78,
            101, 153, 0, 0, 16, 39,
        ];

        let randomness = 0x0101010101010101010101010101010101010101010101010101010101010101;
        let _ = OracleMock::mock("getRandomField").returns(randomness).times(
            (MAX_PRIVATE_LOG_PLAINTEXT_SIZE_IN_BYTES as u64 + 1 + 30) / 31,
        );

        let eph_sk = 0x1358d15019d4639393d62b97e1588c095957ce74a1c32d6ec7d62fe6705d9538;
        let _ = OracleMock::mock("getRandomField").returns(eph_sk).times(1);

        let recipient = AztecAddress::from_field(
            0x25afb798ea6d0b8c1618e50fdeafa463059415013d3b7c75d46abf5e242be70c,
        );

        let sender = AztecAddress::from_field(
            0x25afb798ea6d0b8c1618e50fdeafa463059415013d3b7c75d46abf5e242be70c,
        );

        let _ = OracleMock::mock("getIndexedTaggingSecretAsSender").returns([69420, 1337]);

        let _ = OracleMock::mock("incrementAppTaggingSecretIndexAsSender").returns(());

        let payload = compute_private_log_payload(contract_address, recipient, sender, plaintext);

        // The following value was generated by `encrypted_log_payload.test.ts`
        // --> Run the test with AZTEC_GENERATE_TEST_DATA=1 flag to update test data.
        let private_log_payload_from_typescript = [
            0x0e9cffc3ddd746affb02410d8f0a823e89939785bcc8e88ee4f3cae05e737c36,
            0x008d460c0e434d846ec1ea286e4090eb56376ff27bddc1aacae1d856549f701f,
            0x00a70577790aeabcc2d81ec8d0c99e7f5d2bf2f1452025dc777a178404f851d9,
            0x003de818923f85187871d99bdf95d695eff0a900000000000000000000000000,
            0x000000a600a61f7d59eeaf52eb51bc0592ff981d9ba3ea8e6ea8ba9dc0cec8c7,
            0x000b81e84556a77ce6c3ca47a527f99ffe7b2524bb885a23020b7295748ad19c,
            0x001083618ad96298b76ee07eb1a56d19cc798710e9f5de96501bd59b3781c9c0,
            0x002a6c95c5912f8936b1500d362afbf0922c85b1ada18db8b95162a6e9d06765,
            0x005cdf669eb387f8e0492a95fdcdb39429d5340b4bebc250ba9bf62c2f49f549,
            0x00f37beed75a668aa51967e0e57547e5a655157bcf381e22f30e25881548ec96,
            0x0006a151b5fbfb2d14ee4b34bf4c1dbd71c7be15ad4c63474bb6f89970aeb3d9,
            0x00489c8edbdff80a1a3a5c28370e534abc870a85ea4318326ea19222fb10df35,
            0x008c765edada497db4284ae30507a2e03e983d23cfa0bd831577e857bbef9cf7,
            0x0090c97cb5699cc8783a1b4276d929be2882e5b9b72829a4f8404f7e3c853d11,
            0x00d6d5a000b80134891e95f81007ad35d3945eaeecbe137fff85d01d7eaf8f19,
            0x00a15eb965c6a4bc97aa87fd3463c31c9d4e0d722a8ba870bcc50c9c7a8b48ad,
            0x0063c861bdbe490d44c57382decbae663927909652f87ac18dcfd5b30649cce5,
            0x00820f14caa725efe1fa3485ceac88499eadf0565c5b20998c05931bbf478e68,
        ];

        assert_eq(payload, private_log_payload_from_typescript);
    }

    #[test]
    fn test_incoming_body_ciphertext_matches_typescript() {
        // All the values in this test were copied over from `encrypted_note_log_incoming_body.test.ts`
        let eph_sk = Scalar {
            lo: 0x00000000000000000000000000000000649e7ca01d9de27b21624098b897babd,
            hi: 0x0000000000000000000000000000000023b3127c127b1f29a7adff5cccf8fb06,
        };
        let address_point = AddressPoint {
            inner: Point {
                x: 0x2688431c705a5ff3e6c6f2573c9e3ba1c1026d2251d0dbbf2d810aa53fd1d186,
                y: 0x1e96887b117afca01c00468264f4f80b5bb16d94c1808a448595f115556e5c8e,
                is_infinite: false,
            },
        };
        let plaintext = [
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
        ];

        // `compute_incoming_body_ciphertext(...)` function then derives symmetric key from `eph_sk` and `address_point` and encrypts
        // the note plaintext using AES-128.
        let ciphertext = compute_incoming_body_ciphertext(plaintext, eph_sk, address_point);

        // The following value was generated by `encrypted_note_log_incoming_body.test.ts`.
        // --> Run the test with AZTEC_GENERATE_TEST_DATA=1 flag to update test data.
        let note_body_ciphertext_from_typescript = [
            226, 240, 253, 6, 28, 52, 19, 131, 33, 132, 178, 212, 245, 62, 14, 190, 147, 228, 160,
            190, 146, 61, 95, 203, 124, 153, 68, 168, 17, 150, 92, 0, 99, 214, 85, 64, 191, 78, 157,
            131, 149, 96, 236, 253, 96, 172, 157, 30, 27, 176, 228, 74, 242, 190, 138, 48, 33, 93,
            46, 37, 223, 130, 25, 245, 188, 163, 159, 223, 187, 24, 139, 206, 131, 154, 159, 130,
            37, 17, 158, 114, 242, 141, 124, 193, 232, 54, 146, 96, 145, 100, 125, 234, 57, 43, 95,
            115, 183, 39, 121, 232, 134, 229, 148, 25, 46, 77, 87, 127, 95, 7, 77, 188, 37, 234,
            245, 142, 232, 87, 252, 28, 67, 67, 90, 214, 254, 89, 47, 68, 66, 187, 227, 8, 59, 162,
            25, 141, 97, 141, 217, 197, 115, 15, 212, 202, 157, 41, 150, 62, 219, 57, 224, 92, 185,
            212, 142, 94, 146, 41, 178, 145, 68, 169, 23, 185, 206, 138, 70, 47, 176, 210, 165, 236,
            23, 206, 229, 108,
        ];

        assert_eq(note_body_ciphertext_from_typescript.len(), ciphertext.len());

        for i in 0..note_body_ciphertext_from_typescript.len() {
            assert_eq(ciphertext[i], note_body_ciphertext_from_typescript[i]);
        }
    }
}
