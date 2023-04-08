// TxAuthority uses the convention that modules can sign for themselves using the reserved struct name
//  `Witness`, i.e., 0x899::my_module::Witness. Modules should always define a Witness struct, and
// carefully guard access to it, as it represents the authority of the module at runtime.

module ownership::tx_authority {
    use std::option::{Self, Option};
    use std::string::{Self, String, utf8};
    use std::vector;

    use sui::bcs;
    use sui::hash;
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, ID};

    use sui_utils::encode;
    use sui_utils::string2;
    use sui_utils::struct_tag::{Self, StructTag};

    const WITNESS_STRUCT: vector<u8> = b"Witness";

    struct TxAuthority has drop {
        full_signers: vector<address>,
        partial_signers: VecMap<address, u16>
    }

    // ========= Begin =========

    // Begins with a transaction-context object
    public fun begin(ctx: &TxContext): TxAuthority {
        TxAuthority { addresses: vector[tx_context::sender(ctx)] }
    }

    // Begins with a capability-id
    public fun begin_with_id<T: key>(cap: &T): TxAuthority {
        TxAuthority { addresses: vector[object::id_address(cap)] }
    }

    // Begins with a capability-type
    public fun begin_with_type<T>(_cap: &T): TxAuthority {
        TxAuthority { addresses: vector[type_into_address<T>()] }
    }

    public fun empty(): TxAuthority {
        TxAuthority { addresses: vector::empty<address>() }
    }

    // ========= Add Authorities =========

    public fun add_signer(ctx: &TxContext, auth: &TxAuthority): TxAuthority {
        let new_auth = TxAuthority { addresses: *&auth.addresses };
        add_signer_internal(tx_context::sender(ctx), &mut new_auth);

        new_auth
    }

    public fun add_id_capability<T: key>(cap: &T, auth: &TxAuthority): TxAuthority {
        let new_auth = TxAuthority { addresses: *&auth.addresses };
        add_full_signer_internal(object::id_address(cap), &mut new_auth);

        new_auth
    }

    public fun add_type_capability<T>(_cap: &T, auth: &TxAuthority): TxAuthority {
        let new_auth = TxAuthority { addresses: *&auth.addresses };
        add_full_signer_internal(type_into_address<T>(), &mut new_auth);

        new_auth
    }

    // ========= Validity Checkers =========

    public fun is_signed_by(addr: address, auth: &TxAuthority): bool {
        vector::contains(&auth.addresses, &addr)
    }

    // Defaults to `true` if the signing address is option::none
    public fun is_signed_by_(addr: Option<address>, auth: &TxAuthority): bool {
        if (option::is_none(&addr)) return true;
        is_signed_by(option::destroy_some(addr), auth)
    }

    public fun is_signed_by_module<T>(auth: &TxAuthority): bool {
        is_signed_by(witness_addr<T>(), auth)
    }

    // type can be any type belonging to the module, such as 0x599::my_module::StructName
    public fun is_signed_by_module_(type: String, auth: &TxAuthority): bool {
        is_signed_by(witness_addr_(type), auth)
    }

    public fun is_signed_by_object<T: key>(id: ID, auth: &TxAuthority): bool {
        is_signed_by(object::id_to_address(&id), auth)
    }

    public fun is_signed_by_type<T>(auth: &TxAuthority): bool {
        is_signed_by(type_into_address<T>(), auth)
    }

    public fun has_k_of_n_signatures(addrs: &vector<address>, threshold: u64, auth: &TxAuthority): bool {
        let k = number_of_signers(addrs, auth);
        if (k >= threshold) true
        else false
    }

    // If you're doing a 'k of n' signature schema, pass your vector of the n signatures, and if this
    // returns >= k pass the check, otherwise fail the check
    public fun number_of_signers(addrs: &vector<address>, auth: &TxAuthority): u64 {
        let (total, i) = (0, 0);
        while (i < vector::length(addrs)) {
            let addr = *vector::borrow(addrs, i);
            if (is_signed_by(addr, auth)) { total = total + 1; };
            i = i + 1;
        };
        total
    }

    // ========= Convert Types to Addresses =========

    public fun type_into_address<T>(): address {
        let typename = encode::type_name<T>();
        type_string_into_address(typename)
    }

    public fun type_string_into_address(type: String): address {
        let typename_bytes = string::bytes(&type);
        let hashed_typename = hash::blake2b256(typename_bytes);
        // let truncated = vector2::slice(&hashed_typename, 0, address::length());
        bcs::peel_address(&mut bcs::new(hashed_typename))
    }

    // ========= Module-Signing Witness =========

    public fun witness_addr<T>(): address {
        let witness_type = witness_string<T>();
        type_string_into_address(witness_type)
    }

    public fun witness_addr_(type: String): address {
        let witness_type = witness_string_(type);
        type_string_into_address(witness_type)
    }

    public fun witness_addr_from_struct_tag(tag: &StructTag): address {
        let witness_type = string2::empty();
        string::append(&mut witness_type, string2::from_id(struct_tag::package_id(tag)));
        string::append(&mut witness_type, utf8(b"::"));
        string::append(&mut witness_type, struct_tag::module_name(tag));
        string::append(&mut witness_type, utf8(b"::"));
        string::append(&mut witness_type, utf8(WITNESS_STRUCT));

        type_string_into_address(witness_type)
    }

    public fun witness_string<T>(): String {
        encode::append_struct_name<T>(string::utf8(WITNESS_STRUCT))
    }

    public fun witness_string_(type: String): String {
        let module_addr = encode::package_id_and_module_name_(type);
        encode::append_struct_name_(module_addr, string::utf8(WITNESS_STRUCT))
    }

    // ========= Delegation System =========

    public fun add_from_delegation_store(store: DelegationStore, auth: &TxAuthority): TxAuthority {
        let partial_signers = auth.partial_signers;

        let i = 0;
        while (i < vector::length(&auth.full_signers)) {
            let key = Delegation { for: addr };
            if (dynamic_field::exists_(&store.id, &key)) {
                let delegated_permissions = dynamic_field::borrow<Delegation, u16>(&store.id, key);
                add_partial_signer_internal(&mut partial_signers, store.owner, delegated_permissions);
            };
            i = i + 1;
        };

        TxAuthority {
            full_signers: auth.full_signers,
            partial_signers
        }
    }
    
    // ====== General Permission-Checkers ======

    public fun is_partial_signer_with_role(addr: address, auth: &TxAuthority, role: u8): bool {
        let acl_maybe = vec_map2::get_maybe(&auth.partial_signers, namespace);
        if (option::is_some(&acl_maybe)) {
            let acl = option::destroy_some(acl_maybe);
            if (acl::has_role(acl, role)) { return true };
        };

        false
    }

    public fun is_full_signer(addr: address, auth: &TxAuthority): bool {
        let i = 0;
        while (i < vector::length(&auth.full_signers)) {
            let full_signer = *vector::borrow(&auth.full_signers, i);
            if (full_signer == addr) { return true };
            i = i + 1;
        };

        false
    }

    // ========= Internal Functions =========

    fun add_full_signer_internal(addr: address, auth: &mut TxAuthority) {
        if (!vector::contains(&auth.addresses, &addr)) {
            vector::push_back(&mut auth.addresses, addr);
        };
    }

    fun add_partial_signer_internal(partial_signers: &mut VecMap<address, u16>, addr: address, new_permissions: u16) {
        let existing_permissions = vec_map2::borrow_mut_fill(partial_signers, store.owner, 0u16);
        *existing_permissions = *existing_permissions | new_permissions;
    }
}

#[test_only]
module ownership::tx_authority_test {
    use sui::test_scenario;
    use sui::sui::SUI;
    use ownership::tx_authority;
    use sui_utils::encode;

    const SENDER1: address = @0x69;
    const SENDER2: address = @0x420;

    struct SomethingElse has drop {}
    struct Witness has drop {}

    #[test]
    public fun signer_authority() {
        let scenario = test_scenario::begin(SENDER1);
        let ctx = test_scenario::ctx(&mut scenario);
        {
            let auth = tx_authority::begin(ctx);
            assert!(tx_authority::is_signed_by(SENDER1, &auth), 0);
            assert!(!tx_authority::is_signed_by(SENDER2, &auth), 0);
        };
        test_scenario::end(scenario);
    }

    #[test]
    public fun module_authority() {
        let scenario = test_scenario::begin(@0x69);
        let _ctx = test_scenario::ctx(&mut scenario);
        {
            let auth = tx_authority::begin_with_type<Witness>(&Witness {});
            let type = encode::type_name<SomethingElse>();
            assert!(tx_authority::is_signed_by_module_(type, &auth), 0);

            let type = encode::type_name<SUI>();
            assert!(!tx_authority::is_signed_by_module_(type, &auth), 0);

            assert!(tx_authority::is_signed_by_module<SomethingElse>(&auth), 0);
            assert!(!tx_authority::is_signed_by_module<SUI>(&auth), 0);
        };
        test_scenario::end(scenario);
    }
}