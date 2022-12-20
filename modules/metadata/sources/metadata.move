// Sui's On-Chain TypeMetadata program

// The TypeMetadata object has a corresponding dynamic_field, into which the data is stored.
// Keys correspond to the StructName portion of a fully-qualified type-name: address::module_name::StructName
// StructNames need not exist; for example, the module 0x3::outlaw_sky need not define Outlaw;
// it can just be a virtual-type, that exists inside of noot.struct_name = Outlaw
// The module's one-time witness is the key for module as a whole. So for example, for TypeMetadata<SUI>,
// the key SUI is the metadata for the 0x2::sui module as a whole.

// The intent for metadata object is that they should be owned by the module-deployer, or frozen.
// Making a TypeMetadata object a naked shared-object would allow anyone to be able to mutate it (oh no lol).
// Client-apps will read from TypeMetadata using a devInspect transaction, not a regular transaction

// Data is keyed with type_name + data_name:
// `<package-id>::<module_name>::<struct_name> <package-id>::<module_name>::<struct_name>`

// This means that (1) metadata can define types that they do not own, and (2) metadata can hold multiple
// different data types for different types

module metadata::metadata {
    use std::string::{String, utf8};
    use sui::object::{Self, UID};
    use sui::types;
    use sui::tx_context::{Self, TxContext};
    use sui::dynamic_field;
    use sui::types::is_one_time_witness;
    use utils::encode;
    use noot::noot::Link;

    const ENOT_OWNER: u64 = 0;
    const EMISMATCHED_MODULES: u64 = 1;
    const ENOT_ONE_TIME_WITNESS: u64 = 2;
    const ETYPE_METADATA_ALREADY_DEFINED: u64 = 3;
    const EINVALID_METADATA_CAP: u64 = 4;
    const EIMPROPERLY_SERIALIZED_BATCH_BYTES: u64 = 5;

    // Shared object
    struct ModuleMetadata<phantom G> has key {
        id: UID
    }

    // Shared object
    struct TypeMetadata<phantom T> has key {
        id: UID,
        module_authority: String // edit-authority can be delegated to another module
    }

    struct ObjectMetadata<phantom T> has store {
    }

    // Capability to create and edit metadata for the module that created GENESIS
    struct MetadataCap<phantom GENESIS> has key, store { 
        id: UID
    }

    struct MetadataStore has store, drop {
        slot: String,
        value: vector<u8>
    }

    struct Key has store, copy, drop { slot: String }

    // ========= Create Metadata Objects =========

    public fun define_module<GENESIS: drop>(witness: &GENESIS, ctx: &mut TxContext): MetadataCap<GENESIS> {
        assert!(is_one_time_witness(witness), ENOT_ONE_TIME_WITNESS);

        transfer::share_object(ModuleMetadata<GENESIS> { id: object::new(ctx) });
        MetadataCap<GENESIS> { }
    }

    public entry fun define_type<G: drop, T>(metadata_cap: &mut MetadataCap<G>, ctx: &mut TxContext) {
        let (module_addr, _) = encode::type_name_<T>();
        define_type_(metadata_cap, *string::bytes(&module_addr), ctx);
    }

    public entry fun define_type_<G: drop, T>(metadata_cap: &mut MetadataCap<G>, module_auth_raw: vector<u8>, ctx: &mut TxContext) {
        assert!(encode::is_same_module<G, T>(), EMISMATCHED_MODULES);
        assert!(dynamic_field::exists_(&metadata_cap.id, encode::type_name<T>()), ETYPE_METADATA_ALREADY_DEFINED);

        // This prevents the same typename from being defined twice
        dynamic_field::add(&metadata_cap.id, encode::type_name<T>(), true);

        transfer::share_object(TypeMetadata<T> {
            id: object::new(ctx),
            module_authority: string::utf8(module_auth_raw)
        });
    }

    // ========= Modify Attributes =========

    public entry fun add_module_attribute<G: drop>(
        cap: &MetadataCap<G>,
        module: &mut ModuleMetadata<G>,
        slot: String,
        bytes: vector<u8>
    ) {
        remove_module_attribute<G, Value>(cap, module, slot);
        dynamic_field::add(&mut module.id, Key { slot }, bytes);
    }

    public entry fun remove_module_attribute<G: drop>(_cap: &MetadataCap<G>, module: &mut ModuleMetadata<G>, slot: String) {
        if (dynamic_field::exists_(&module.id, Key { slot })) {
            dynamic_field::remove<Key, vector<u8>>(&mut module.id, Key { slot });
        };
    }

    public entry fun add_type_attribute<G: drop, T>(
        cap: &MetadataCap<G>,
        type: &mut TypeMetadata<T>,
        slot: String,
        bytes: vector<u8>
    ) {
        remove_type_attribute<G, T, Value>(cap, type, slot);
        dynamic_field::add(&mut type.id, Key { slot }, bytes);
    }

    public entry fun remove_type_attribute<G: drop, T>(
        _cap: &MetadataCap<G>,
        type: &mut TypeMetadata<T>,
        slot: String
    ) {
        assert!(is_valid(cap, type), EINVALID_METADATA_CAP);

        if (dynamic_field::exists_(&type.id, Key { slot })) {
            dynamic_field::remove<Key, vector<u8>>(&mut type.id, Key { slot });
        };
    }

    // ========= Batch-Add Attributes =========

    // Encoded as: [ key: String, value_type: vector<u8> ]
    // Unfortunately bcs does not support peeling strings, so we're just working with raw types
    public entry fun add_module_attributes<G: drop>(
        cap: &MetadataCap<G>,
        module: &mut ModuleMetadata<G>,
        attribute_pairs: vector<vector<u8>>
    ) {
        let (i, length) = (0, vector::length(&attribute_pairs));
        assert!(length % 2 == 0, EIMPROPERLY_SERIALIZED_BATCH_BYTES);

        while (i < length) {
            let slot = utf8(*vector::borrow(&attribute_pairs, i));
            let bytes = *vector::borrow(&attribute_pairs, i + 1);
            add_module_attribute(cap, module, slot, bytes);
            i = i + 2;
        };
    }

    public entry fun add_type_attributes() {

    }

    // Requires module authority
    // Only requires ownership authority of the metadata is already set
    public fun batch_add_attributes<World: drop>(_witness: World, id: &mut UID, attribute_pairs: vector<vector<u8>>, ctx: &TxContext): World {
        assert!(module_authority::is_valid<World>(id), ENO_MODULE_AUTHORITY);
        assert!(ownership::is_valid_owner(id, tx_context::sender(ctx)), ENOT_OWNER);

        let (i, length) = (0, vector::length(&attribute_pairs));
        assert!(length % 2 == 0, EIMPROPERLY_SERIALIZED_BATCH_BYTES);

        while (i < length) {
            let slot = utf8(*vector::borrow(&attribute_pairs, i));
            let bytes = *vector::borrow(&attribute_pairs, i + 1);
            dynamic_field::add(id, slot, bytes);
            i = i + 2;
        };
    }

    // ========= Make Metadata Immutable =========

    // Being able to freeze shared objects is currently being worked on; when it's available, freeze the module here along with
    // the metadata_cap being destroyed.
    public fun destroy_metadata_cap<G: drop>(metadata_cap: MetadataCap<G>) {
        let MetadataCap { id } = metadata_cap;
        object::delete(id);
    }

    // Not currently possible
    public fun freeze_module<G: drop>(cap: &MetadataCap<G>, module: ModuleMetadata<G>) {
        transfer::freeze_object(module);
    }

    // Not currently possible
    public fun freeze_type<T>(cap: &MetadataCap<G>, type: TypeMetadata<T>) {
        assert!(is_valid(cap, type), EINVALID_METADATA_CAP);
        transfer::freeze_object(type);
    }

    // ============== View Functions for Client apps ============== 

    // Should we return the keys (query_slots) back along with the bytes?
    public fun get_module_attributes(module: &ModuleMetadata, query_slots: vector<vector<u8>>): vector<vector<u8>> {
        let (i, response) = (0, vector::empty<vector<u8>>());

        while (i < vector::length(&query_slots)) {
            let slot = utf8(*vector::borrow(&query_slots, i));

            // We leave an empty vector of bytes if the slot does not have any value
            if (dynamic_field::exists_(&module.id, Key { slot })) {
                vector::push_back(&mut response, *dynamic_field::borrow<Key, vector<u8>>(&module.id, slot));
            } else {
                vector::push_back(&mut response, vector::empty<u8>());
            };
            i = i + 1;
        };

        response
    }

    public fun get_module_attribute<G>(module: &ModuleMetadata<G>, slot_raw: vector<u8>): Option<vector<u8>> {
        let key = Key { slot: utf8(slot_raw) };
        if (!dynamic_field::exists_(&module.id, key)) { 
            return option::none()
        };
        
        option::some(*dynamic_field::borrow<Key, vector<u8>>(&module.id, key))
    }

    public fun get_type_attribute<T>(type: &TypeMetadata<T>, slot_raw: vector<u8>): Option<vector<u8>> {
        let key = Key { slot: utf8(slot_raw) };
        if (!dynamic_field::exists_(&type.id, key)) { 
            return option::none() 
        };

        option::some(*dynamic_field::borrow<Key, vector<u8>>(&type.id, key))
    }

    // This first checks id for module_addr + data = Data. That is, a record stored on UID that
    // corresponds to module_addr G, with the corresponding Data type. If it's not found, it falls
    // back to using the TypeMetadata object for module G.
    public fun for_object<G, Data: store + copy + drop>(
        id: &UID,
        type_name: String,
        metadata: &TypeMetadata<G>
    ): Data {
        let (key, _) = encode::type_name_<G>();
        string::append(&mut key, encode::type_name<Data>());

        if (dynamic_field::exists_with_type<String, Data>(id, key)) {
            dynamic_field::borrow<String, Data>(id, key)
        } else {
            get_<G, Data>(metadata, type_name)
        }
    }

    public fun for_object_cannonical<G, Data: store + copy + drop>(
        id: &UID,
        type_name: String,
        metadata: &TypeMetadata<G>
    ): Data {
        let (module_addr1, _) = encode::type_name_<G>();
        let (module_addr2, _) = encode::decompose_type_name(type_name);
        assert!(module_addr1 == module_addr2, ENOT_CANONICAL_TYPE);

        for_object<G, Data>(id, type_name, metadata)
    }

    // ========= Authority Checkers =========

    public fun is_valid<G: drop, T>(cap: &MetadataCap<G>, type: &TypeMetadata<T>): bool {
        let (module_addr, _) = encode::type_name_<G>();
        *type.module_authority == module_addr
    }
}