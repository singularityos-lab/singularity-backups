[CCode (cheader_filename = "sodium.h", lower_case_cprefix = "")]
namespace Sodium {
    [CCode (cname = "sodium_init")]
    public int init ();

    [CCode (cname = "randombytes_buf")]
    public void random_bytes ([CCode (array_length_type = "size_t")] uint8[] buffer);

    [CCode (cname = "sodium_memzero")]
    public void memzero ([CCode (array_length_type = "size_t")] uint8[] buffer);

    [CCode (cname = "crypto_secretstream_xchacha20poly1305_ABYTES")]
    public const int STREAM_ABYTES;
    [CCode (cname = "crypto_secretstream_xchacha20poly1305_HEADERBYTES")]
    public const int STREAM_HEADERBYTES;
    [CCode (cname = "crypto_secretstream_xchacha20poly1305_KEYBYTES")]
    public const int STREAM_KEYBYTES;
    [CCode (cname = "crypto_secretstream_xchacha20poly1305_TAG_MESSAGE")]
    public const uint8 TAG_MESSAGE;
    [CCode (cname = "crypto_secretstream_xchacha20poly1305_TAG_FINAL")]
    public const uint8 TAG_FINAL;

    [CCode (cname = "crypto_secretstream_xchacha20poly1305_state", has_type_id = false, destroy_function = "")]
    public struct StreamState {
    }

    [CCode (cname = "crypto_secretstream_xchacha20poly1305_init_push")]
    public int stream_init_push (ref StreamState state, [CCode (array_length = false)] uint8[] header, [CCode (array_length = false)] uint8[] key);

    [CCode (cname = "crypto_secretstream_xchacha20poly1305_push")]
    public int stream_push (ref StreamState state, [CCode (array_length = false)] uint8[] cipher, out uint64 cipher_length,
                            [CCode (array_length = false)] uint8[] message, uint64 message_length,
                            [CCode (array_length = false)] uint8[]? additional, uint64 additional_length, uint8 tag);

    [CCode (cname = "crypto_secretstream_xchacha20poly1305_init_pull")]
    public int stream_init_pull (ref StreamState state, [CCode (array_length = false)] uint8[] header, [CCode (array_length = false)] uint8[] key);

    [CCode (cname = "crypto_secretstream_xchacha20poly1305_pull")]
    public int stream_pull (ref StreamState state, [CCode (array_length = false)] uint8[] message, out uint64 message_length, out uint8 tag,
                            [CCode (array_length = false)] uint8[] cipher, uint64 cipher_length,
                            [CCode (array_length = false)] uint8[]? additional, uint64 additional_length);

    [CCode (cname = "crypto_pwhash_SALTBYTES")]
    public const int PWHASH_SALTBYTES;
    [CCode (cname = "crypto_pwhash_ALG_ARGON2ID13")]
    public const int PWHASH_ARGON2ID13;
    [CCode (cname = "crypto_pwhash_OPSLIMIT_INTERACTIVE")]
    public const uint64 PWHASH_OPSLIMIT_INTERACTIVE;
    [CCode (cname = "crypto_pwhash_MEMLIMIT_INTERACTIVE")]
    public const size_t PWHASH_MEMLIMIT_INTERACTIVE;

    [CCode (cname = "crypto_pwhash")]
    public int pwhash ([CCode (array_length = false)] uint8[] output, uint64 output_length, string password, uint64 password_length,
                       [CCode (array_length = false)] uint8[] salt, uint64 opslimit, size_t memlimit, int algorithm);

    [CCode (cname = "crypto_kdf_derive_from_key")]
    public int kdf_derive ([CCode (array_length_type = "size_t")] uint8[] subkey, uint64 subkey_id, string context,
                           [CCode (array_length = false)] uint8[] key);

    [CCode (cname = "crypto_generichash")]
    public int generichash ([CCode (array_length_type = "size_t")] uint8[] output,
                            [CCode (array_length_type = "unsigned long long")] uint8[] input,
                            [CCode (array_length_type = "size_t")] uint8[]? key);
}
