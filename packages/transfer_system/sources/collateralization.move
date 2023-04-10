module transfer_system::collateralization {
    use std::option;

    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{TxContext};
    use sui::dynamic_field;

    use ownership::ownership;
    use ownership::tx_authority::{Self, TxAuthority};

    use sui_utils::struct_tag;

    struct Witness has drop { }

    struct Request<phantom A, phantom C> has key, store {
        id: UID,
        /// The ID of the asset to requested be borrowed
        asset_id: ID,
        /// The ID of the asset to being offered as collateral
        collateral_id: ID,
        /// The date when the asset is expected to be returned
        due_date: u64,
        /// The period of time which the asset return can be delayed with after the due date has elapsed
        grace_period: u64,
        /// The status of the request
        status: u8
    }

    // `CData`, short for `CollateralData` or `CollateralizationData`
    struct CData has store, drop {
        request_id: ID,
        collateral_id: ID,
        lender: vector<address>
    }

    struct Key has store, copy, drop { }

    // ========== Error enums ==========
    const ENO_OWNER_AUTH: u64 = 0;
    const EINVALID_ASSET_LENDER: u64 = 1;
    const EINVALID_OBJECT_TYPE: u64 = 2;
    const EINVALID_DUE_DATE: u64 = 3;
    const EASSET_ID_MISMATCH: u64 = 4;
    const ECOLLATERAL_ID_MISMATCH: u64 = 5;

    // Request status enums
    const REQUEST_INITIALIZED: u8 = 0;
    const REQUEST_ACCEPTED: u8 = 1;
    const REQUEST_REJECTED: u8 = 2;
    const REQUEST_COMPLETED: u8 = 3;
    const REQUEST_OVERDUE: u8 = 4;

    public fun initialize<A: key, C: key>(
        clock: &Clock,
        asset: &UID,
        collateral: &UID,
        due_date: u64,
        ctx: &mut TxContext
    ) {
        let request = initialize_<A, C>(clock, asset, collateral, due_date, ctx);
        transfer::share_object(request)
    }

    public fun initialize_<A: key, C: key>(
        clock: &Clock,
        asset: &UID,
        collateral: &UID,
        due_date: u64,
        ctx: &mut TxContext
    ): Request<A, C> {
        // Ensures that the collateralization initializer owns the collateral item
        let auth = tx_authority::begin(ctx);
        assert!(ownership::is_authorized_by_owner(collateral, &auth), ENO_OWNER_AUTH);
        
        // Ensures that the collateral type is valid
        assert!(match_object_type<C>(collateral), EINVALID_OBJECT_TYPE);

        // Ensures that the asset type is valid
        assert!(match_object_type<A>(asset), EINVALID_OBJECT_TYPE);
       
        // Ensures that the due date is in the future
        assert!(clock::timestamp_ms(clock) < due_date, EINVALID_DUE_DATE);

        let request = Request {
            id: object::new(ctx),
            asset_id: object::uid_to_inner(asset),
            collateral_id: object::uid_to_inner(collateral),
            status: REQUEST_INITIALIZED,
            grace_period: 0,
            due_date,
        };

        request
    }

    public fun accept<A: key, C: key>(
        request: &mut Request<A, C>,
        clock: &Clock,
        asset: &mut UID,
        collateral: &mut UID,
        grace_period: u64,
        auth: &TxAuthority
    ) {
        // Ensures that the collateralization accepter owns the asset
        assert!(ownership::is_authorized_by_owner(asset, auth), ENO_OWNER_AUTH);

        // Ensures that the specified collateral and asset matches the request's
        assert!(object::uid_to_inner(asset) == request.asset_id, EASSET_ID_MISMATCH);
        assert!(object::uid_to_inner(collateral) == request.collateral_id, ECOLLATERAL_ID_MISMATCH);

        // Ensures that the due date is in the future
        assert!(clock::timestamp_ms(clock) < request.due_date, EINVALID_DUE_DATE);

        // Update the grace period provided
        request.grace_period = request.grace_period + grace_period;

        let lender = ownership::get_owner(asset);
        let requester = ownership::get_owner(collateral);

        // TODO: update the collateral asset. Ensure that it's locked (non transferrable)

        // Attach the collateralization data to the asset
        let c_data = CData {
            request_id: object::id(request),
            lender: option::destroy_some(lender),
            collateral_id: object::uid_to_inner(collateral),
        };
        dynamic_field::add<Key, CData>(asset, Key { }, c_data);

        // Trasfer asset to the collateralization requester
        let auth = tx_authority::begin_with_type(&Witness {});
        ownership::transfer(asset, option::destroy_some(requester), &auth);
    }

    // ========== Helper functions ===========

    fun match_object_type<T>(object: &UID): bool {
        let object_type = ownership::get_type(object);
        assert!(option::is_some(&object_type), 0);

        option::destroy_some(object_type) == struct_tag::get<T>()
    }
}