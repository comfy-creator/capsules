// Balance can be frozen by the coin-creator
// Rebilling
// Funded holds
// Fees on send
// Market-confounding (fixed price)
// Non-transferable
// 
// Out of scope:
// Privacy at some point later (confidential + anonymous transfers)
// Consumer protection
// Dev protection (infinite money glitch)
// Crank (hydra), split-balance, joint-accounts

// Plan:
// - Inside of an account, place a 'this person can remove XX amount' record. Must include
// an expiration time, refresh time, refresh rate, locked balance
// - Cranks exist with inbound and outbound funds
// - Transfer authority exists for balances; plugin
// - Cancellable by guardian

// Thoughts:
// - We opted for a simple uniform transfer system here. Transfers check for frozen-balances,
// non-transferability, and fees. This fits most use-cases. A more advanced system would have
// its own transfer-module, just like Capsules does.
// - Accounts are non-transferrable; you transfer balances within Accounts rather than ownership of
// the entire account.

module economy::account {
    use std::option::{Self, Option};
    use std::type_name::{Self, TypeName};
    use std::vector;

    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::dynamic_field;
    use sui::linked_table::{Self as map, LinkedTable as Map};
    use sui::object::{Self, UID};
    use sui::package;
    // use sui::display;
    use sui::transfer;
    use sui::tx_context::TxContext;
    use sui::math;

    use sui_utils::linked_table2 as map2;
    use sui_utils::typed_id;

    use ownership::action::ADMIN;
    use ownership::ownership;
    use ownership::tx_authority::{Self, TxAuthority};

    // Constants
    const ONE_DAY: u64 = 1000 * 60 * 60 * 24;
    const ONE_YEAR: u64 = 1000 * 60 * 60 * 24 * 365;

    // Error constants
    const ENO_OWNER_AUTHORITY: u64 = 0;
    const ENO_PACKAGE_AUTHORITY: u64 = 1;
    const EINVALID_REBILL: u64 = 2;
    const EACCOUNT_FROZEN: u64 = 3;
    const EINVALID_TRANSFER: u64 = 4;
    const EINVALID_EXPORT: u64 = 5;
    const ENO_MERCHANT_AUTHORITY: u64 = 6;
    const ECURRENCY_CANNOT_BE_TRANSFERRED: u64 = 7;
    const EINVALID_HOLD: u64 = 8;
    const EHOLD_EXPIRED: u64 = 9;
    const EINVALID_TRANSFER_FEE: u64 = 10;
    const ECURRENCY_ALREADY_REGISTERED: u64 = 11;
    const EFREEZE_DISABLED: u64 = 12;

    struct ACCOUNT has drop { } // One-time-witness
    struct Witness has drop { } // Package-authority

    // Root-level shared object
    struct Account<phantom T> has key {
        id: UID,
        available: Balance<T>,
        rebills: Map<address, vector<Rebill>>, // merchant-address -> rebills available
        held_funds: Map<address, Hold<T>>,
        frozen: bool
    }

    // This is useful for cancel-at-will rebills, such as a gym membership. If the merchant misses a rebill
    // window, the rebill amounts _do not_ stack. Amounts available refresh, rather than stack, between
    // rebill cycles.
    // The merchant is not required to bill the full available amount; the available amount is a cap.
    // This works for usage-based billing, where the total amount due is not known ahead of time.
    // Neither fixed-rebill nor usage-based-rebill are funded or guaranteed.
    //
    // This is not useful for buy-now-pay-later uncollateralized payment plans. In that case, you'd
    // specify some maximum amount to be paid in total, along with a payment cadence, and allow the loan
    // to be paid back early, and remove the ability to cancel-at-will.
    // 
    // Has its own identifier (id) for easy reference because a merchant may have several rebills against
    // a single Account
    struct Rebill has store, copy, drop {
        available: u64, // available to be withdrawn in the current period
        refresh_amount: u64, // max balance that can be withdrawn per refresh
        refresh_cadence: u64, // ms interval
        last_refresh: u64 // ms timestamp
    }

    struct Hold<phantom T> has store {
        funds: Balance<T>,
        expiry_ms: u64 // timestamp
    }

    // Action types for end-users
    struct WITHDRAW {} // used by account-owner and merchant to withdraw

    // =========== End-User API ===========
    // Used by the owner of the account

    // You can create an account for any type `T`, however there is no guarantee that a currency
    // of that type actually exists (lol).
    public fun create_account<T>(ctx: &mut TxContext): Account<T> {
        Account { 
            id: object::new(ctx),
            available: balance::zero(),
            rebills: map::new(ctx),
            held_funds: map::new(ctx),
            frozen: false
        }
    }

    public fun return_and_share<T>(account: Account<T>, owner: address) {
        let auth = tx_authority::begin_with_package_witness_(Witness { });
        let typed_id = typed_id::new(&account);

        // Accounts are non-transferable, hence transfer-auth is set to @0x0
        ownership::as_shared_object_(&mut account.id, typed_id, owner, @0x0, &auth);

        transfer::share_object(account);
    }

    // Deposits are permissionless
    public fun import_from_balance<T>(account: &mut Account<T>, balance: Balance<T>) {
        assert!(!account.frozen, EACCOUNT_FROZEN);

        balance::join(&mut account.available, balance);
    }

    public entry fun import_from_coin<T>(account: &mut Account<T>, coin: Coin<T>) {
        assert!(!account.frozen, EACCOUNT_FROZEN);

        balance::join(&mut account.available, coin::into_balance(coin));
    }

    // Requires permission from the `Account` owner and that user-transfers are allowed OR
    // requires permission from the package itself, and that creator-transfers are allowed.
    // This is an Account -> Account transfer, and hence keeps all balances within our closed system,
    // allowing creators to ensure their conditions are followed.
    public fun transfer<T>(
        from: &mut Account<T>,
        to: &mut Account<T>,
        amount: u64,
        registry: &CurrencyRegistry,
        auth: &TxAuthority,
        ctx: &mut TxContext
    ) {
        assert!(is_valid_transfer(from, registry, auth), EINVALID_TRANSFER);
        assert!(!from.frozen && !to.frozen, EACCOUNT_FROZEN);

        let fee = pay_transfer_fee(from, amount, registry, ctx);
        balance::join(&mut to.available, balance::split(&mut from.available, amount - fee));
    }

    public fun export_to_balance<T>(
        account: &mut Account<T>,
        registry: &CurrencyRegistry,
        amount: u64,
        auth: &TxAuthority
    ): Balance<T> {
        assert!(is_valid_export(account, registry, auth), EINVALID_EXPORT);
        assert!(!account.frozen, EACCOUNT_FROZEN);

        balance::split(&mut account.available, amount)
    }

    public fun export_to_coin<T>(
        account: &mut Account<T>,
        registry: &CurrencyRegistry,
        amount: u64,
        auth: &TxAuthority,
        ctx: &mut TxContext
    ): Coin<T> {
        assert!(is_valid_export(account, registry, auth), EINVALID_EXPORT);
        assert!(!account.frozen, EACCOUNT_FROZEN);

        coin::from_balance(balance::split(&mut account.available, amount), ctx)
    }

    // This doesn't work yet because shared-objects cannot be destroyed
    // Will abort if any funds are available or held. Frozen status is ignored since the account is empty.
    public fun destroy_empty_account<T>(account: Account<T>, auth: &TxAuthority) {
        assert!(ownership::can_act_as_owner<WITHDRAW>(&account.id, auth), ENO_OWNER_AUTHORITY);

        let Account { id, available, rebills, held_funds, frozen: _ } = account;
        object::delete(id);
        balance::destroy_zero(available);
        map::drop(rebills);
        map::destroy_empty(held_funds);
    }

    // This also doesn't work yet; shared objects cannot be destroyed
    // Aborts if any funds are currently held for someone else
    // This only works for the owner or currency-creator, not a DeFi-integration partner
    public fun destroy_account<T>(account: Account<T>, registry: &CurrencyRegistry, auth: &TxAuthority): Balance<T> {
        assert!(is_valid_export(&account, registry, auth), EINVALID_EXPORT);
        assert!(!account.frozen, EACCOUNT_FROZEN);

        let Account { id, available, rebills, held_funds, frozen: _ } = account;
        object::delete(id);
        map::drop(rebills);
        map::destroy_empty(held_funds);

        available
    }

    // =========== Merchant API ===========
    // Used by merchants to deposit to or withdraw from accounts
    // Rebill: amount max, refresh cadence (user can always cancel)
    // Hold: amount max, expiry (end-user can always withdraw)

    // Action type
    // Allows withdrawing from rebill and holds. Can also release holds. This allows a merchant to
    // outsource the collection of their funds.
    struct MERCHANT { }

    // Refresh cadence must be 24 hours or longer, amount must be more than 0.
    // We do not impose a limit on the number of rebills that can be created.
    // `merchant_addr` is the authority-address that is allowed to withdraw for the rebill.
    public fun add_rebill<T>(
        customer: &mut Account<T>,
        merchant_addr: address,
        max_amount: u64,
        refresh_cadence: u64,
        clock: &Clock,
        registry: &CurrencyRegistry,
        auth: &TxAuthority
    ) {
        assert!(refresh_cadence >= ONE_DAY, EINVALID_REBILL);
        assert!(max_amount > 0, EINVALID_REBILL);

        // Checks if the `Account` owner or creator authorized this
        assert!(ownership::can_act_as_owner<WITHDRAW>(&customer.id, auth), ENO_OWNER_AUTHORITY);
        assert!(is_currency_transferable<T>(registry), ECURRENCY_CANNOT_BE_TRANSFERRED);
        assert!(!customer.frozen, EACCOUNT_FROZEN);

        let rebill = Rebill {
            available: 0, // not available until first refresh
            refresh_amount: max_amount,
            refresh_cadence,
            last_refresh: clock::timestamp_ms(clock)
        };

        let rebills = map2::borrow_mut_fill<address, vector<Rebill>>(
            &mut customer.rebills, merchant_addr, vector[]);
        vector::push_back(rebills, rebill);
    }

    // Requires MERCHANT action from the owner of `merchant` account.
    public fun withdraw_with_rebill<T>(
        customer: &mut Account<T>,
        merchant: &mut Account<T>,
        rebill_index: u64, // in case multiple rebills exist for this merchant
        amount: u64,
        clock: &Clock,
        registry: &CurrencyRegistry,
        auth: &TxAuthority,
        ctx: &mut TxContext
    ) {
        let merchant_addr = option::destroy_some(ownership::get_owner(&merchant.id));
        assert!(tx_authority::can_act_as_address<MERCHANT>(merchant_addr, auth), ENO_MERCHANT_AUTHORITY);
        assert!(is_currency_transferable<T>(registry), ECURRENCY_CANNOT_BE_TRANSFERRED);
        assert!(!customer.frozen && !merchant.frozen, EACCOUNT_FROZEN);

        let rebills = map::borrow_mut<address, vector<Rebill>>(&mut customer.rebills, merchant_addr);
        let rebill = vector::borrow_mut(rebills, rebill_index);

        crank_rebill(rebill, clock);
        rebill.available = rebill.available - amount; // Aborts if `amount` > rebill.available

        let fee = pay_transfer_fee(customer, amount, registry, ctx);
        balance::join(&mut merchant.available, balance::split(&mut customer.available, amount - fee));
    }

    // Rebill can be cancelled either by the account owner or the merchant
    public fun cancel_rebill<T>(
        customer: &mut Account<T>,
        merchant_addr: address,
        rebill_index: u64,
        auth: &TxAuthority
    ) {
        assert!(ownership::can_act_as_owner<WITHDRAW>(&customer.id, auth)
            || tx_authority::can_act_as_address<MERCHANT>(merchant_addr, auth), ENO_OWNER_AUTHORITY);
        
        let rebills = map::borrow_mut(&mut customer.rebills, merchant_addr);
        vector::swap_remove(rebills, rebill_index);
        if (vector::length(rebills) == 0) {
            map::remove(&mut customer.rebills, merchant_addr);
        };
    }

    public fun cancel_all_rebills_for_merchant<T>(
        customer: &mut Account<T>,
        merchant_addr: address,
        auth: &TxAuthority
    ) {
        assert!(ownership::can_act_as_owner<WITHDRAW>(&customer.id, auth)
            || tx_authority::can_act_as_address<MERCHANT>(merchant_addr, auth), ENO_OWNER_AUTHORITY);
        
        map::remove(&mut customer.rebills, merchant_addr);
    }

    public fun add_hold<T>(
        customer: &mut Account<T>,
        merchant_addr: address,
        amount: u64,
        duration_ms: u64,
        clock: &Clock,
        registry: &CurrencyRegistry,
        auth: &TxAuthority
    ) {
        assert!(duration_ms <= ONE_YEAR, EINVALID_HOLD);
        assert!(amount > 0, EINVALID_HOLD);

        // Checks if the `Account` owner or creator authorized this
        assert!(ownership::can_act_as_owner<WITHDRAW>(&customer.id, auth), ENO_OWNER_AUTHORITY);
        assert!(is_currency_transferable<T>(registry), ECURRENCY_CANNOT_BE_TRANSFERRED);
        assert!(!customer.frozen, EACCOUNT_FROZEN);

        let expiry_ms = clock::timestamp_ms(clock) + duration_ms;

        if (map::contains(&customer.held_funds, merchant_addr)) {
            let hold = map::borrow_mut(&mut customer.held_funds, merchant_addr);
            // Users cannot decrease the duration of an existing hold by creating a new hold
            hold.expiry_ms = math::max(hold.expiry_ms, expiry_ms);
            balance::join(&mut hold.funds, balance::split(&mut customer.available, amount));
        } else {
            let hold = Hold {
                funds: balance::split(&mut customer.available, amount),
                expiry_ms
            };
            map::push_back(&mut customer.held_funds, merchant_addr, hold);
        };
    }

    public fun withdraw_from_held_funds<T>(
        customer: &mut Account<T>,
        merchant: &mut Account<T>,
        amount: u64,
        clock: &Clock,
        registry: &CurrencyRegistry,
        auth: &TxAuthority,
        ctx: &mut TxContext
    ) {
        let merchant_addr = option::destroy_some(ownership::get_owner(&merchant.id));
        assert!(tx_authority::can_act_as_address<MERCHANT>(merchant_addr, auth), ENO_MERCHANT_AUTHORITY);
        assert!(is_currency_transferable<T>(registry), ECURRENCY_CANNOT_BE_TRANSFERRED);
        assert!(!customer.frozen && !merchant.frozen, EACCOUNT_FROZEN);

        let fee = pay_transfer_fee(customer, amount, registry, ctx);

        let hold = map::borrow_mut(&mut customer.held_funds, merchant_addr);
        assert!(hold.expiry_ms >= clock::timestamp_ms(clock), EHOLD_EXPIRED);

        balance::join(&mut merchant.available, balance::split(&mut hold.funds, amount - fee));
        if (balance::value(&hold.funds) == 0) {
            release_hold_internal(customer, merchant_addr);
        };
    }

    // This will work even if the currency is non-transferable now or the account is frozen
    public fun release_held_funds<T>(
        customer: &mut Account<T>,
        merchant_addr: address,
        auth: &TxAuthority
    ) {
        assert!(tx_authority::can_act_as_address<MERCHANT>(merchant_addr, auth), ENO_MERCHANT_AUTHORITY);

        release_hold_internal(customer, merchant_addr);
    }

    // =========== Package Authority Actions ===========
    // These functions can only be called on `Coin<T>` with `T` package-authority. Meaning they can only
    // be called by (1) on-chain, by the package-itself, using a Witness struct, or (2) off-chain, by
    // whoever owns the Organization object that contains the package.

    // User Transfer Enum. From less-permissive (0) to most permissive (1)
    const NO_TRANSFER: u8 = 0;
    const NO_EXPORT: u8 = 1;
    const OPEN_EXPORT: u8 = 2;

    // Stores all CurrencyConfig objects
    // Shared, root-level singleton object.
    struct CurrencyRegistry has key {
        id: UID
    }

    // Note that `controlled` must be set to `true` upon creation in order to enable control of the
    // currency.
    //
    // Controlled currency:
    // - Creator (package-id or org with package-id) can withdraw balances. Useful for games involving
    // off-chain logic.
    // - Creator can freeze / unfreeze balances. Frozen balances cannot be withdrawn by the owner or
    // creator. This is a business requirement for Circle. Note that existing holds will still be
    // available, even if an `Account` is frozen.
    // - Transfer-fee optionally imposes a fee for each transfer. This is only imposed on transfers,
    // and not when balances are exported.
    // - `user_transfer_enum` allows a user to export Account as `Balance` or `Coin` if greater than 1.
    // Note that currencies exported outside of `Account` cannot be controlled in any way by the creator,
    // hence allowing this is discouraged.
    // If `user_transer_enum` is > 0, then the user can also do Account <-> Account transfers
    // - `export_auths` is a set of addresses (package-id, orgs, or individals) that are allowed to
    // export `Account`. This is necessary to integrate with DeFi. The integrating-DeFi contract must
    // be careful to make sure that it does not allow users or other untrusted programs to export.
    // That is, you can only do `Account` -> Trusted-DeFi -> `Account` and not -> `Coin`.
    // This limits what DeFi apps can do with a given currency, creating a permissioned system, but it
    // protect's creator controls from being bypassed. I.e., someone could bypass freezing or transfer-
    // fees by simple forking this package and creating a version with CurrencyControls removed.
    //
    // Uncontrolled currency:
    // - Users can convert `Account` to 'Balance' or 'Coin'. This enables permissionless DeFi integration
    // - Creator cannot freeze, withdraw, or make account non-transferable
    // - there is no need for an integration white-list; integration is permissionless
    //
    // Currencies can go from non-permissive -> permissive, but not in reverse. That is, currencies can
    // never become less permissive
    struct CurrencyControls<phantom T> has store {
        creator_can_withdraw: bool,
        creator_can_freeze: bool,
        user_transfer_enum: u8,
        transfer_fee: Option<TransferFee>,
        export_auths: vector<address>
    }

    struct TransferFee has store, copy, drop {
        bps: u64, // 100 bps = 1%
        pay_to: address // will be exported as 'Coin' to this address, for simplicity
    }

    // Action types for packages
    struct FREEZE {} // for Account<T>, this is used by T's declaring-package to freeze accounts

    // A currency can only be registered once. Currencies can only become more permissive, not less
    public fun register_currency<T: drop>(
        registry: &mut CurrencyRegistry,
        creator_can_withdraw: bool,
        creator_can_freeze: bool,
        user_transfer_enum: u8,
        transfer_fee_bps: Option<u64>,
        transfer_fee_addr: Option<address>,
        export_auths: vector<address>,
        auth: &TxAuthority
    ) {
        let key = type_name::get<T>();
        assert!(tx_authority::can_act_as_package<T, ADMIN>(auth), ENO_PACKAGE_AUTHORITY);
        assert!(!dynamic_field::exists_(&registry.id, key), ECURRENCY_ALREADY_REGISTERED);

        let transfer_fee = transfer_fee_struct(transfer_fee_bps, transfer_fee_addr);

        let controls = CurrencyControls<T> {
            creator_can_withdraw,
            creator_can_freeze,
            user_transfer_enum,
            transfer_fee,
            export_auths
        };

        dynamic_field::add(&mut registry.id, key, controls);
    }

    public fun freeze_<T>(account: &mut Account<T>, registry: &CurrencyRegistry, auth: &TxAuthority) {
        let controls = dynamic_field::borrow<TypeName, CurrencyControls<T>>(&registry.id, type_name::get<T>());
        assert!(controls.creator_can_freeze, EFREEZE_DISABLED);
        assert!(tx_authority::can_act_as_package<T, FREEZE>(auth), ENO_PACKAGE_AUTHORITY);

        account.frozen = true;
    }

    public fun unfreeze<T>(account: &mut Account<T>, auth: &TxAuthority) {
        assert!(tx_authority::can_act_as_package<T, FREEZE>(auth), ENO_PACKAGE_AUTHORITY);

        account.frozen = false;
    }

    // This is permanent
    public fun disable_creator_withdraw<T>(registry: &mut CurrencyRegistry, auth: &TxAuthority) {
        assert!(tx_authority::can_act_as_package<T, ADMIN>(auth), ENO_PACKAGE_AUTHORITY);

        let controls = dynamic_field::borrow_mut<TypeName, CurrencyControls<T>>(
            &mut registry.id, type_name::get<T>());
        controls.creator_can_withdraw = false;
    }

    // This is permanent
    public fun disable_freeze_ability<T>(registry: &mut CurrencyRegistry, auth: &TxAuthority) {
        assert!(tx_authority::can_act_as_package<T, ADMIN>(auth), ENO_PACKAGE_AUTHORITY);

        let controls = dynamic_field::borrow_mut<TypeName, CurrencyControls<T>>(
            &mut registry.id, type_name::get<T>());
        controls.creator_can_freeze = false;
    }

    public fun set_transfer_policy<T>(
        registry: &mut CurrencyRegistry,
        user_transfer_enum: u8,
        export_auths: vector<address>,
        auth: &TxAuthority
    ) {
        assert!(tx_authority::can_act_as_package<T, ADMIN>(auth), ENO_PACKAGE_AUTHORITY);

        let controls = dynamic_field::borrow_mut<TypeName, CurrencyControls<T>>(
            &mut registry.id, type_name::get<T>());
        
        controls.user_transfer_enum = user_transfer_enum;
        controls.export_auths = export_auths;
    }

    public fun set_transfer_fee<T>(
        registry: &mut CurrencyRegistry,
        transfer_fee_bps: Option<u64>,
        transfer_fee_addr: Option<address>,
        auth: &TxAuthority
    ) {
        assert!(tx_authority::can_act_as_package<T, ADMIN>(auth), ENO_PACKAGE_AUTHORITY);

        let controls = dynamic_field::borrow_mut<TypeName, CurrencyControls<T>>(
            &mut registry.id, type_name::get<T>());
        controls.transfer_fee = transfer_fee_struct(transfer_fee_bps, transfer_fee_addr);
    }

    // =========== Internal Utility Functions ===========

    // Must remain private, or we need an auth-check added here so arbitrary people cannot withdraw
    // from `Account`
    fun pay_transfer_fee<T>(
        account: &mut Account<T>,
        amount: u64,
        registry: &CurrencyRegistry,
        ctx: &mut TxContext
    ): u64 {
        let (fee, fee_addr) = calculate_transfer_fee<T>(amount, registry);

        if (fee > 0 && option::is_some(&fee_addr)) {
            let balance = balance::split(&mut account.available, fee);
            let coin = coin::from_balance(balance, ctx);
            transfer::public_transfer(coin, option::destroy_some(fee_addr));
        };

        fee
    }

    fun transfer_fee_struct(bps: Option<u64>, addr: Option<address>): Option<TransferFee> {
        if (option::is_some(&bps) && option::is_some(&addr)) {
            assert!(*option::borrow(&bps) > 0, EINVALID_TRANSFER_FEE);

            option::some(TransferFee { 
                bps: option::destroy_some(bps), 
                pay_to: option::destroy_some(addr)
            })
        } else {
            option::none()
        }
    }

    // =========== Crank System ===========
    // These can be called permisionlessly; they update rebills and holds based on time

    public fun crank<T>(account: &mut Account<T>, clock: &Clock) {
        // Crank Rebills
        let key_maybe = *map::front(&account.rebills);
        while (option::is_some(&key_maybe)) {
            let merchant_addr = *option::borrow(&key_maybe);
            let rebills = map::borrow_mut(&mut account.rebills, merchant_addr);
            let i = 0;
            while (i < vector::length(rebills)) {
                let rebill = vector::borrow_mut(rebills, i);
                crank_rebill(rebill, clock);
                i = i + 1;
            };

            key_maybe = *map::next(&account.rebills, merchant_addr);
        };

        // Crank Holds
        let key_maybe = *map::front(&account.held_funds);
        while (option::is_some(&key_maybe)) {
            let merchant_addr = *option::borrow(&key_maybe);
            key_maybe = *map::next(&account.held_funds, merchant_addr);
            let hold = map::borrow(&account.held_funds, merchant_addr);

            if (hold.expiry_ms < clock::timestamp_ms(clock)) {
                release_hold_internal(account, merchant_addr);
            };
        };
    }

    public fun crank_rebill(rebill: &mut Rebill, clock: &Clock) {
        let current_time = clock::timestamp_ms(clock);

        if (current_time >= rebill.last_refresh + rebill.refresh_cadence) {
            let cycles = (((current_time - rebill.last_refresh) / rebill.refresh_cadence) as u128);
            rebill.last_refresh = 
                rebill.last_refresh + (((rebill.refresh_cadence as u128) * cycles) as u64);
            rebill.available = rebill.refresh_amount;
        };
    }

    fun release_hold_internal<T>(account: &mut Account<T>, merchant_addr: address) {
        let hold = map::remove(&mut account.held_funds, merchant_addr);
        let Hold { funds, expiry_ms: _ } = hold;
        balance::join(&mut account.available, funds);
    }

    // =========== Getter Functions ===========

    public fun is_valid_export<T>(account: &Account<T>, registry: &CurrencyRegistry, auth: &TxAuthority): bool {
        let key = type_name::get<T>();
        if (dynamic_field::exists_(&registry.id, key)) {
            let controls = dynamic_field::borrow<TypeName, CurrencyControls<T>>(&registry.id, key);

            (controls.user_transfer_enum > NO_EXPORT && ownership::can_act_as_owner<WITHDRAW>(&account.id, auth))
                || (controls.creator_can_withdraw && tx_authority::can_act_as_package<T, WITHDRAW>(auth))
        } else {
            ownership::can_act_as_owner<WITHDRAW>(&account.id, auth)
        }
    }

    // This is orthogonal to whether or not the transfer is allowed
    public fun calculate_transfer_fee<T>(amount: u64, registry: &CurrencyRegistry): (u64, Option<address>) {
        let key = type_name::get<T>();

        if (dynamic_field::exists_(&registry.id, key)) {
            let controls = dynamic_field::borrow<TypeName, CurrencyControls<T>>(&registry.id, key);
            
            // Calculate transfer fee if it exists
            if (option::is_some(&controls.transfer_fee)) {
                let transfer_fee = option::borrow(&controls.transfer_fee);
                let fee = (((transfer_fee.bps as u128) * (amount as u128) / 10_000u128) as u64);

                (fee, option::some(transfer_fee.pay_to))
            } else { 
                (0, option::none()) 
            }
        } else {
            (0, option::none())
        }
    }

    public fun is_currency_transferable<T>(registry: &CurrencyRegistry): bool {
        let key = type_name::get<T>();

        if (dynamic_field::exists_(&registry.id, key)) {
            let controls = dynamic_field::borrow<TypeName, CurrencyControls<T>>(&registry.id, key);
            (controls.user_transfer_enum > NO_TRANSFER)
        } else {
            true
        }
    }

    // Returns `true` if the transfer is allowed, `false` otherwise.
    public fun is_valid_transfer<T>(account: &Account<T>, registry: &CurrencyRegistry, auth: &TxAuthority): bool {
        let key = type_name::get<T>();

        if (dynamic_field::exists_(&registry.id, key)) {
            let controls = dynamic_field::borrow<TypeName, CurrencyControls<T>>(&registry.id, key);
            
            // Check if the user or creator are allowed to withdraw, and have sufficient permission
            (controls.user_transfer_enum > NO_TRANSFER &&
                ownership::can_act_as_owner<WITHDRAW>(&account.id, auth))
                || (controls.creator_can_withdraw && tx_authority::can_act_as_package<T, WITHDRAW>(auth))
        } else {
            ownership::can_act_as_owner<WITHDRAW>(&account.id, auth)
        }
    }

    // =========== Init Function ===========

    #[allow(unused_function)]
    // Creates the CurrencyRegistry and claims display
    fun init(otw: ACCOUNT, ctx: &mut TxContext) {
        transfer::share_object(CurrencyRegistry {
            id: object::new(ctx)
        });

        let publisher = package::claim(otw, ctx);
        // transfer::public_transfer(display::new<Account>(&publisher, ctx), tx_context::sender(ctx));
        package::burn_publisher(publisher);
    }

    // =========== Convenience Entry Functions ===========
    // Makes life easier for client-apps

    public entry fun create_account_<T>(owner: address, ctx: &mut TxContext) {
        let account = create_account<T>(ctx);
        return_and_share(account, owner);
    }

    public entry fun charge_and_rebill<T>(
        customer: &mut Account<T>,
        merchant: &mut Account<T>,
        amount: u64,
        rebill_cadence: u64,
        clock: &Clock,
        registry: &CurrencyRegistry,
        ctx: &mut TxContext
    ) {
        let auth = tx_authority::begin(ctx);
        let merchant_addr = option::destroy_some(ownership::get_owner(&merchant.id));

        transfer(customer, merchant, amount, registry, &auth, ctx);
        add_rebill(customer, merchant_addr, amount, rebill_cadence, clock, registry, &auth);
    }

    public entry fun grant_currency() { }
    
    public entry fun destroy_currency() { }
}