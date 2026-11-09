// GATT layout of the Settle Up BLE service (SPEC 8.7.2). Frozen: phones on
// different builds must agree on these.

/// The one primary service every Settle Up peripheral exposes. Scanners
/// filter on it; it is also the only UUID in the advertisement.
const String kBleServiceUuid = '82101e6c-f454-4ceb-86a8-5375a3b1a414';

/// INFO (read): UTF-8 JSON `{"v":1,"d":..,"n":..,"t":[..]}`, see
/// `BleInfo`.
const String kBleInfoUuid = 'cdc76358-cfae-4208-855b-5d0c5b179f6a';

/// RX (write with response): central -> peripheral chunks.
const String kBleRxUuid = 'fb7ee064-81d8-47d5-87dc-a89a5e02dbe7';

/// TX (notify): peripheral -> central chunks.
const String kBleTxUuid = '33453450-cada-4c25-afb0-ba2115611155';

/// Local name in the advertisement (iOS allows only a name and service
/// UUIDs, and the 31-byte packet has little room).
const String kBleLocalName = 'SU';

/// MTU the Android central asks for (the most Android allows).
const int kBleRequestedMtu = 517;
