// Note that for addresses (and IDs) BCS doesn't do any validation; you can use non-hex
// strings even when it's configured for hex-addresses and it won't abort. The 0x prefix
// is optional and doens't affect anything.

import { BCS, BcsConfig, EnumTypeDefinition, BcsWriter, BcsReader } from '@mysten/bcs';
import { DevInspectResults } from '@mysten/sui.js';
import {
  is,
  object,
  integer,
  bigint,
  string,
  boolean,
  record,
  array,
  union,
  any,
  Struct,
  define
} from 'superstruct';

// ===== Declared Supported Types =====

const supportedTypes = [
  'address',
  'bool',
  'ID',
  'u8',
  'u16',
  'u32',
  'u64',
  'u128',
  'u256',
  'String',
  'Url',
  'vector<u8>',
  'VecMap'
] as const;

type SupportedMoveTypes =
  | (typeof supportedTypes)[number]
  | `Option<${(typeof supportedTypes)[number]}>`;

type SupportedJSTypes =
  | Uint8Array
  | boolean
  | number
  | bigint
  | string
  | number[]
  | Record<string, string>
  | URL
  | { none: null }
  | { some: string };

type JSTypes<T extends Record<string, keyof MoveToJSTypes>> = {
  -readonly [K in keyof T]: MoveToJSTypes[T[K]];
};

type MoveToJSTypes = {
  address: string;
  bool: boolean;
  ID: string;
  u8: number;
  u16: number;
  u32: number;
  u64: bigint;
  u128: bigint;
  u256: bigint;
  String: string;
  Url: URL;
  'vector<address>': string[];
  'vector<bool>': boolean[];
  'vector<ID>': string[];
  'vector<u8>': Uint8Array;
  'vector<u16>': Uint16Array;
  'vector<u32>': Uint32Array;
  'vector<u64>': BigUint64Array;
  'vector<u128>': BigInt[];
  'vector<u256>': BigInt[];
  'vector<String>': string[];
  'vector<Url>': string[];
  'vector<vector<u8>>': Uint8Array[];
  VecMap: Record<string, string>;
  'Option<address>': { none: null } | { some: string };
  'Option<bool>': { none: null } | { some: boolean };
  'Option<ID>': { none: null } | { some: string };
  'Option<u8>': { none: null } | { some: number };
  'Option<u16>': { none: null } | { some: number };
  'Option<u32>': { none: null } | { some: number };
  'Option<u64>': { none: null } | { some: bigint };
  'Option<u128>': { none: null } | { some: bigint };
  'Option<u256>': { none: null } | { some: bigint };
  'Option<String>': { none: null } | { some: string };
  'Option<Url>': { none: null } | { some: string };
  'Option<vector<address>>': { none: null } | { some: string[] };
  'Option<vector<bool>>': { none: null } | { some: boolean[] };
  'Option<vector<ID>>': { none: null } | { some: string[] };
  'Option<vector<u8>>': { none: null } | { some: Uint8Array };
  'Option<vector<u16>>': { none: null } | { some: Uint16Array };
  'Option<vector<u32>>': { none: null } | { some: Uint32Array };
  'Option<vector<u64>>': { none: null } | { some: BigUint64Array };
  'Option<vector<u128>>': { none: null } | { some: BigInt[] };
  'Option<vector<u256>>': { none: null } | { some: BigInt[] };
  'Option<vector<String>>': { none: null } | { some: string[] };
  'Option<vector<Url>>': { none: null } | { some: string[] };
  'Option<vector<vector<u8>>>': { none: null } | { some: Uint8Array[] };
  'Option<VecMap>': { none: null } | { some: Record<string, string> };
};

// ===== Define Option enums =====

let enums: { [key: string]: EnumTypeDefinition } = {};

supportedTypes.forEach((typeName) => {
  enums[`Option<${typeName}>`] = {
    none: null,
    some: typeName,
  };

  enums[`Option<vector<${typeName}>>`] = {
    none: null,
    some: `vector<${typeName}>`,
  };
});

// ===== Instantiate bcs =====

const SUI_ADDRESS_LENGTH = 32;
let bcsConfig: BcsConfig = {
  vectorType: 'vector<T>',
  addressLength: SUI_ADDRESS_LENGTH,
  addressEncoding: 'hex',
  genericSeparators: ['<', '>'],
  types: { enums },
  withPrimitives: true,
};

let bcs = new BCS(bcsConfig);

// ===== Register String, Url, and VecMap<String,String> custom serializers =====

bcs.registerAlias('ID', BCS.ADDRESS);

bcs.registerType(
  "String",
  (writer, data: string) => {
    let bytes = new TextEncoder().encode(data);
    writer.writeVec(Array.from(bytes), (w, el) => w.write8(el));
    return writer;
  },
  (reader: BcsReader) => {
    let bytes = reader.readBytes(reader.readULEB());
    return new TextDecoder("utf8").decode(bytes);
  },
  (value) => is(value, MoveToStruct["String"])
);

// This is identical to the String writer / reader
bcs.registerType(
  "Url",
  (writer, data: string) => {
    let bytes = new TextEncoder().encode(data);
    writer.writeVec(Array.from(bytes), (w, el) => w.write8(el));
    return writer;
  },
  (reader: BcsReader) => {
    let bytes = reader.readBytes(reader.readULEB());
    return new URL(new TextDecoder("utf8").decode(bytes));
  },
  (value) => is(value, MoveToStruct["Url"])
);

// This is a custom serializer for primitive types; for now we treat VecMap as a struct type rather than
// a primitive type
bcs.registerType(
  "VecMap",
  (writer, data: Record<string, string>) => {
    writer.writeULEB(Object.entries(data).length);
    let strings = Object.entries(data).flat();

    let byteArray = strings.map((string) => {
      return new TextEncoder().encode(string);
    });

    byteArray.forEach((bytes) => {
      writer.writeVec(Array.from(bytes), (w, el) => w.write8(el));
    });
    return writer;
  },
  (reader) => {
    let data: Record<string, string> = {};

    reader.readVec((reader) => {
      let key = new TextDecoder("utf8").decode(reader.readBytes(reader.readULEB()));
      let value = new TextDecoder("utf8").decode(reader.readBytes(reader.readULEB()));
      data[key] = value;
    });

    return data;
  },
  (value) => is(value, MoveToStruct["VecMap"])
);

// bcs.registerStructType('VecMap', {
//   contents: 'vector<Entry>'
// });

// bcs.registerStructType('Entry', {
//   k: 'String',
//   v: 'String'
// });

// ===== Register Aliases =====

bcs.registerAlias("UID", "address");

// ===== Configure SuperStruct to allow for runtime validation =====

const UrlSchema = define("url", (value: unknown): value is URL => {
  return value instanceof URL;
});

const MoveToStruct: Record<string, Struct<any, any>> = {
  address: array(integer()),
  bool: boolean(),
  ID: array(integer()),
  u8: integer(),
  u16: integer(),
  u32: integer(),
  u64: bigint(),
  u128: bigint(),
  u256: bigint(),
  String: string(),
  Url: UrlSchema,
};

Object.keys(MoveToStruct).map((field) => {
  MoveToStruct[`vector<${field}>`] = array(MoveToStruct[field]);
});

MoveToStruct["vector<vector<u8>>"] = array(array(integer()));
MoveToStruct["VecMap"] = record(string(), string());

Object.keys(MoveToStruct).map((field) => {
  MoveToStruct[`Option<${field}>`] = union([object({ none: any() }), object({ some: MoveToStruct[field] })]);
});

/**
 * Generates a Move Struct validator from a provided schema.
 *
 * @param {Record<string, string>} schema - an object that maps keys of data to their data types.
 * @returns {Struct<{ [x: string]: any }, Record<string, any>>} - a Move Struct validator with fields matching the provided schema.
 */
function moveStructValidator(schema: Record<string, string>): Struct<{ [x: string]: any }, Record<string, any>> {
  const dynamicStruct: Record<string, any> = {};

  Object.keys(schema).map((key) => {
    dynamicStruct[key] = MoveToStruct[schema[key]];
  });

  return object(dynamicStruct);
}

// function serializeBcs(bcs: BCS, dataType: string, data: SupportedJSTypes): number[] {
//   return Array.from(bcs.ser(dataType, data).toBytes());
// }

// function deserializeBcs(bcs: BCS, dataType: string, byteArray: Uint8Array): Record<string, string> {
//   return bcs.de(dataType, byteArray);
// }

/**
 * Serializes data into an array of arrays of bytes using the provided BCS, schema, and optionally a list of onlyKeys.
 *
 * @param {BCS} bcs - the Byte Conversion Service to be used for serialization.
 * @param {any} data - the data to be serialized.
 * @param {Record<string, string>} schema - an object that maps keys of data to their data types.
 * @param {string[]} [onlyKeys] - an optional list of keys to be serialized.
 * @returns {number[][]} - an array of arrays of bytes representing the serialized data.
 */
function serializeByField(
  bcs: BCS,
  data: Record<string, SupportedJSTypes>,
  schema: Record<string, string>,
  onlyKeys?: string[]
): number[][] {
  const serializedData: number[][] = [];
  if (!onlyKeys) {
    for (const [key, keyType] of Object.entries(schema)) {
      const bytesArray = Array.from(bcs.ser(keyType, data[key]).toBytes());
      serializedData.push(bytesArray);
    }
  } else {
    onlyKeys.forEach((key) => {
      const bytesArray = Array.from(bcs.ser(schema[key], data[key]).toBytes());
      serializedData.push(bytesArray);
    });
  }

  return serializedData;
}

function newSerializer(
  bcs: BCS,
  data: Record<string, SupportedJSTypes>,
  schema: Record<string, string>
): [number[][], string[][]] {
  const serializedData: number[][] = [];
  const schemaFields: string[][] = [];

  for (const [key, keyType] of Object.entries(schema)) {
    const bytesArray = Array.from(bcs.ser(keyType, data[key]).toBytes());
    serializedData.push(bytesArray);

    schemaFields.push([key, keyType]);
  }

  return [serializedData, schemaFields];
}

/**
 * Deserializes an array of arrays of bytes into a Record of key-value pairs using the provided BCS and schema.
 *
 * @param {BCS} bcs - the Byte Conversion Service to be used for deserialization.
 * @param {Uint8Array[]} bytesArray - the array of arrays of bytes to be deserialized.
 * @param {Record<string, string>} schema - an object that maps keys of data to their data types.
 * @param {string[]} [keys] - an optional list of keys to be deserialized.
 * @returns {Record<string, string> | null} - a Record of key-value pairs representing the deserialized data, or null if the number of keys and bytesArray length do not match.
 */
function deserializeByField<T>(
  bcs: BCS,
  bytesArray: Uint8Array[],
  schema: Record<string, string>,
  keys?: string[]
): Record<string, string> | null {
  let deserializedData: Record<string, string> = {};
  if (keys && bytesArray.length !== keys?.length) {
    throw Error("Number of keys to deserialize must be equal to bytesArray length.");
  }
  const iterable = keys || Object.keys(schema);
  iterable.forEach((key, index) => {
    const data = bcs.de(schema[key], new Uint8Array(bytesArray[index]));
    deserializedData[key] = data;
  });
  return deserializedData;
}

// ===== Sui Response parsers and utility-functions =====

function parseViewResultsFromStruct(result: DevInspectResults): Uint8Array {
  // @ts-ignore
  return new Uint8Array(result.results.Ok[0][1].returnValues[0][0]);
}

// If the on-chain move function is returning a vector of bytes, a useless length vector will be
// prepended that we must remove. The client must know what type of response to expect and use this
// or the above function
function parseViewResultsFromVector(result: DevInspectResults): Uint8Array {
  // @ts-ignore
  const data = new Uint8Array(result.results.Ok[0][1].returnValues[0][0]);
  let [_, dataCrop] = sliceULEB128(data);
  return dataCrop;
}

function sliceULEB128(array: Uint8Array, start: number = 0): [number, Uint8Array] {
  let total = 0;
  let shift = 0;
  let len = 0;

  while (true) {
    if (len > 4) {
      throw "No ULEB128 found";
    }

    let byte = array[start + len];
    total = total | ((byte & 0x7f) << shift);

    if ((byte & 0x80) == 0) {
      break;
    }

    shift = shift + 7;
    len = len + 1;
  }

  return [total, array.slice(start + len + 1, array.length)];
}

const schemaToStringArray = (schema: Record<string, SupportedJSTypes>): string[][] => {
  return Object.keys(schema).map((key) => {
    return [key, String(schema[key])];
  });
};

export {
  SupportedMoveTypes,
  SupportedJSTypes,
  JSTypes,
  bcs,
  serializeByField,
  deserializeByField,
  parseViewResultsFromStruct,
  parseViewResultsFromVector,
  moveStructValidator,
  sliceULEB128,
  schemaToStringArray,
  newSerializer,
};
