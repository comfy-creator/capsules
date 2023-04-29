// Namespaces establish a single address that holds multiple packages within it. Such as a studio
// publishing multiple packages and then unifying all their server-permissions underneath a single principal
// address.
// A Namespace can store the RBAC records for an entire organization.
// The intent is that the Namespace object will be owned by a master-key, which is a multi-sig wallet,
// stored safely offline, and then used to grant various admin keypairs to servers. The rights of these servers
// can be carefully scoped, and keypairs rotated in and out using the master-key.
//
// Namespaces can also be used to delegate authority from a keypair to other addresses.
// A potential abuse vector is that a malicious actor could trick a user into mistakenly signing a
// namespace::create() transaction, creating a Namespace object for that user's keypair, while setting the
// malcious actor as the owner of it. If this were to occur, the malicious actor would have permanent control
// over the user's keypair. To prevent this, we disallow transferring ownership of Namespace objects created
// outside of using a publish_receipt, and the owner is permanently the principal.
//
// Security note: the principal address of a namespace is the package-id of the publish-receipt used to
// create it initially, or the user's address who created it initially. For security, we should
// make sure it's impossible to do tx_authority::add_id() with the package-id of the published
// package somehow, otherwise the security of namespaces will be compromised. In that case we'll
// use an alternative address as the principal address (perhaps a hash of something or just a random
// 32 byte value?).
//
// If you want to rotate the master-key for a namespace, you can simply send the namespace to a new
// address using SimpleTransfer.

module ownership::namespace {
    use std::option;
    use std::string::String;
    use std::vector;

    use sui::dynamic_field;
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    use sui_utils::encode;
    use sui_utils::typed_id;
    use sui_utils::vec_map2;
    
    use ownership::ownership;
    use ownership::permissions::{Self, Permission, SingleUsePermission};
    use ownership::publish_receipt::{Self, PublishReceipt};
    use ownership::rbac::{Self, RBAC};
    use ownership::simple_transfer::Witness as SimpleTransfer;
    use ownership::tx_authority::{Self, TxAuthority};

    // Error enums
    const ENO_PERMISSION: u64 = 0;
    const ENO_OWNER_AUTHORITY: u64 = 1;
    const EPACKAGE_ALREADY_CLAIMED: u64 = 2;
    const EPACKAGES_MUST_BE_EMPTY: u64 = 3;
    const ENO_MODULE_AUTHORITY: u64 = 4;

    // Shared, root-level object.
    // The principal (address) is stored within the RBAC, and cannot be changed after creation
    struct Namespace has key {
        id: UID,
        packages: vector<ID>,
        rbac: RBAC
    }

    // Placed on PublishReceipt to prevent namespaces from being claimed twice
    struct Key has store, copy, drop {}

    // Permission type
    struct REMOVE_PACKAGE {}
    struct ADD_PACKAGE {}
    struct SINGLE_USE {} // issue single-use permissions on behalf of the namespace

    // Authority object
    struct Witness has drop {}

    // ======== Create Namespaces ======== 

    // Convenience entry function
    public entry fun create_from_package(receipt: &mut PublishReceipt, ctx: &mut TxContext) {
        let namespace = create_from_package_(receipt, tx_context::sender(ctx), ctx);
        return_and_share(namespace);
    }

    // Claim a namespace object from a publish receipt.
    // The principal (address) will be the first package-ID used. We can combine several packags under the
    // same namespace.
    public fun create_from_package_(
        receipt: &mut PublishReceipt,
        owner: address,
        ctx: &mut TxContext
    ): Namespace {
        let package_id = publish_receipt::into_package_id(receipt);
        let rbac = rbac::create_internal(package_id);

        let namespace = Namespace { 
            id: object::new(ctx),
            packages: vector::empty(), 
            rbac 
        };

        // Initialize ownership
        let typed_id = typed_id::new(&namespace);
        let auth = tx_authority::begin_with_type(&Witness { });
        ownership::as_shared_object<Namespace, SimpleTransfer>(&mut namespace.id, typed_id, owner, &auth);

        add_package_internal(receipt, &mut namespace);

        namespace
    }

    public fun return_and_share(namespace: Namespace) {
        transfer::share_object(namespace);
    }

    // Note that this is currently not callable, because Sui does not yet support destroying shared
    // objects. To destroy a namespace, you must first remove any packages from it; this is to
    // prevent packages from being permanently orphaned without a namespace.
    public fun destroy(namespace: Namespace) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);
        assert!(vector::is_empty(&namespace.packages), EPACKAGES_MUST_BE_EMPTY);

        let Namespace { id, packages: _, rbac: _ } = namespace;
        object::delete(id);
    }

    // ======== Edit Namespaces =====
    // You must be the owner of a namespace to edit it. If you want to change owners, call into SimpleTransfer.
    // Ownership of namespaces created with anything other than a publish_receipt are non-transferable.

    // This is a special strut that acts as an intermediary to transfer packages between namespaces.
    // This is necessary because Sui does not support multi-signer-transactions, so we cannot do this
    // exchange atomically in a single transaction. Rather, the sender must first remove the package from its
    // namespace and send it to the intended recipient. The recipient must then merge it into their namespace.
    struct StoredPackage has key, store {
        id: UID,
        package: ID
    }

    // Only the namespace owner can add the package
    public fun add_package(receipt: &mut PublishReceipt, namespace: &mut Namespace, auth: &TxAuthority) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        add_package_internal(receipt, namespace);
    }

    // Ensures that a publish-receipt (package) can only ever be claimed once
    fun add_package_internal(receipt: &mut PublishReceipt, namespace: &mut Namespace) {
        let receipt_uid = publish_receipt::uid_mut(receipt);
        assert!(!dynamic_field::exists_(receipt_uid, Key { }), EPACKAGE_ALREADY_CLAIMED);
        dynamic_field::add(receipt_uid, Key { }, true);

        let package_id = publish_receipt::into_package_id(receipt);
        vector::push_back(&mut namespace.packages, package_id);
    }

    // Convenience function. Must be called by the namespace-owner address. Transfer the package
    // to this owner address.
    public entry fun remove_package(namespace: &mut Namespace, package_id: ID, ctx: &mut TxContext) {
        let auth = tx_authority::begin(ctx);
        let stored_package = remove_package(namespace, package_id, &auth, ctx);
        transfer::transfer(stored_package, tx_context::sender(ctx));
    }

    public fun remove_package_(
        namespace: &mut Namespace,
        package_id: ID,
        auth: &TxAuthority,
        ctx: &mut TxContext
    ): StoredPackage {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        let package = vector::remove(&mut namespace.packages, package_id);
        StoredPackage {
            id: object::new(ctx),
            package
        }
    }

    public fun add_package_from_stored(namespace: &mut Namespace, stored_package: StoredPackage, auth: &TxAuthority) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        let StoredPackage { id, package } = stored_package;
        object::delete(id);

        vector::push_back(&mut namespace.packages, package);
    }

    // ======== RBAC Editor ========
    // This is just a pass-through layer into RBAC itself + authority-checking + pass-through
    // The RBAC editor is private, and can only be accessed via this namespace module

    public entry fun set_role_for_agent(namespace: &mut Namespace, agent: address, role: String) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        rbac::set_role_for_agent(&mut namespace.rbac, agent, role);
    }

    public entry fun grant_admin_role_for_agent(namespace: &mut Namespace, agent: address) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        rbac::grant_admin_role_for_agent(&mut namespace.rbac, agent);
    }

    public entry fun grant_manager_role_for_agent(namespace: &mut Namespace, agent: address) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        rbac::grant_manager_role_for_agent(&mut namespace.rbac, agent);
    }

    public entry fun delete_agent(namespace: &mut Namespace, agent: address) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        rbac::delete_agent(&mut namespace.rbac, agent);
    }

    public entry fun grant_permission_to_role<Permission>(namespace: &mut Namespace, role: String) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        rbac::grant_permission_to_role<Permission>(&mut namespace.rbac, role);
    }

    public entry fun revoke_permission_from_role<Permission>(namespace: &mut Namespace, role: String) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        rbac::revoke_permission_from_role<Permission>(&mut namespace.rbac, role);
    }

    public entry fun delete_role_and_agents(namespace: &mut Namespace, role: String) {
        assert!(ownership::has_owner_admin_permission(&namespace.id, auth), ENO_OWNER_AUTHORITY);

        rbac::delete_role_and_agents(&mut namespace.rbac, role);
    }

    public fun has_owner_or_admin_permission(uid: &UID, auth: &TxAuthority): bool {
        ownership::is_owner(uid, auth) || 
        // TO DO
    }

    // ======== For Agents ========
    // Agents should call into this to retrieve any permissions assigned to them and stored within the
    // namespace. These permissions are brought into the current transaction-exeuction to pass validity-
    // checks later.

    public fun claim_permissions(namespace: &Namespace, ctx: &TxContext): TxAuthority {
        let agent = tx_context::sender(ctx);
        let auth = tx_authority::begin(ctx);
        auth = claim_permissions_for_agent(namespace, agent, &auth);
        tx_authority::add_namespace_internal(namespace.packages, principal(namespace), &auth)
    }

    public fun claim_permissions_(namespace: &Namespace, auth: &TxAuthority): TxAuthority {
        let i = 0;
        let agents = tx_authority::agents(auth);
        while (i < vector::length(&agents)) {
            let agent = *vector::borrow(&agents, i);
            auth = claim_permissions_for_agent(namespace, agent, auth);
            i = i + 1;
        };
        
        tx_authority::add_namespace_internal(namespace.packages, principal(namespace), &auth)
    }

    // This function could safely be public, but we want users to use one of the above-two functions
    fun claim_permissions_for_agent(namespace: &Namespace, agent: address, auth: &TxAuthority): TxAuthority {
        let permissions = rbac::get_agent_permissions(&namespace.rbac, agent);
        let principal = principal(namespace);
        tx_authority::add_permissions_internal(principal, agent, permissions, auth)
    }

    // Convenience function
    public fun assert_login<Permission>(namespace: &Namespace, ctx: TxContext): TxAuthority {
        let auth = tx_authority::begin(ctx);
        assert_login_<Permission>(namespace, &auth)
    }

    // Log the agent into the namespace, and assert that they have the specified permission
    public fun assert_login_<Permission>(namespace: &Namespace, auth: &TxAuthority): TxAuthority {
        let auth = claim_permissions_(namespace, auth);
        let principal = rbac::principal(&namespace.rbac);
        assert!(tx_authority::has_permission<Permission>(principal, &auth), ENO_PERMISSION);

        auth
    }

    // ======== Single Use Permissions ========

    // In order to issue a single-use permission, the agent calling into this must:
    // (1) have (namespace, Permission); the agent already has this permission (or higher), and
    // (2) have (namespace, SINGLE_USE); the agent was granted the authority to issue single-use permissions 
    // (or is an admin; the manager role is not sufficient)
    public fun create_single_use_permission<Permission>(
        auth: &TxContext,
        ctx: &mut TxContext
    ): SingleUsePermission {
        assert!(tx_authority::has_permission_excluding_manager<Permission, SINGLE_USE>(auth), ENO_OWNER_AUTHORITY);
        assert!(tx_authority::has_permission<Permission>(auth), ENO_OWNER_AUTHORITY);

        let principal = option::destroy_some(tx_authority::lookup_namespace_for_package<Permission>(auth));
        permissions::create_single_use<Permission>(principal, ctx)
    }

    // This is a module-witness pattern; this is equivalent to a storable Witness
    public fun create_single_use_permission_from_witness<Witness: drop, Permission>(
        _witness: Witness,
        ctx: &mut TxContext
    ): SingleUsePermission {
        // This ensures that the Witness supplied is the module-authority Witness corresponding to `Permission`
        assert!(tx_authority::is_module_authority<Witness, Permission>(), ENO_MODULE_AUTHORITY);

        permissions::create_single_use<Permission>(encode::type_into_address<Witness>(), ctx)
    }

    // ======== Getter Functions ========

    public fun principal(namespace: &Namespace): address {
        rbac::principal(&namespace.rbac)
    }

    public fun packages(namespace: &Namespace): vector<ID> {
        namespace.packages
    }

    // ======== Extend Pattern ========

    public fun uid(namespace: &Namespace): &UID {
        &namespace.id
    }

    public fun uid_mut(namespace: &mut Namespace, auth: &TxAuthority): &mut UID {
        assert!(ownership::validate_uid_mut(&namespace.id, auth), ENO_PERMISSION);

        &mut namespace.id
    }

}

    // ======== Namespace Provisioning ========
    // If we want a namespace to have access to a non-native object, the owner must explicitly
    // call into ownership::provision() and provision the namespace. From there the namespace
    // can access the object's UID and write data to its own namespace.
    // Namespaces can only be explicitly deleted by the namespace itself, even if the object-owner
    // changes.

    // Used to check which namespaces have access to this object
    // struct Key has store, copy, drop { namespace: address } 

    // // permission type
    // struct PROVISION {} // allows provisioning and de-provisioning of namespaces

    // public fun provision(uid: &mut UID, namespace: address, auth: &TxAuthority) {
    //     assert!(tx_authority::has_permission<PROVISION>(namespace, auth), ENO_OWNER_AUTHORITY);

    //     dynamic_field2::set(uid, Key { namespace }, true);
    // }

    // public fun deprovision(uid: &mut UID, namespace: address, auth: &TxAuthority) {
    //     assert!(tx_authority::has_permission<PROVISION>(namespace, auth), ENO_NAMESPACE_AUTHORITY);

    //     dynamic_field2::drop(uid, Key { namespace })
    // }

    // public fun is_provisioned(uid: &UID, namespace: address): bool {
    //     dynamic_field::exists_(uid, Key { namespace })
    // }

    // TO DO: we might want to auto-provision a namespace upon access to inventory or data::attach,
    // so that access cannot be lost in the future.
    // We might remove the type-checks in the future for PROVISION and make UID have referential-authority


    // UPDATE: I think it's simply too dangerous to allow regular users to create Namespaces.
    // We restrict namespaces to only projects who are deploying packages, since they can be
    // assumed to have tighter security and greater security knowledge.

    // Convenience entry function
    // public entry fun create(ctx: &mut TxContext) {
    //     create_(tx_context::sender(ctx), &tx_authority::begin(ctx), ctx);
    // }

    // Create a namespace object for an address; packages will be empty but can be added later
    // Instead of returning the Namespace here, we force you to use a second transaction
    // to edit it; this is a safety measure. If a user were tricked into creating this, the
    // malicious actor will need to trick the user into signing a second transaction after this,
    // adding permissions to the Namespace object created here.
    // public fun create_(principal: address, auth: &TxAuthority, ctx: &mut TxContext) {
    //     assert!(tx_authority::has_admin_permission(principal, auth), ENO_ADMIN_AUTHORITY);

    //     let rbac = rbac::create(principal, &auth);
    //     let namespace = Namespace { 
    //         id: object::new(ctx),
    //         packages: vector::empty(), 
    //         rbac 
    //     };

    //     // Initialize ownership
    //     let typed_id = typed_id::new(&namespace);
    //     let auth = tx_authority::begin_with_type(&Witness { });
    //     // Owner == principal, and ownership of this object can never be changed since we do not
    //     // assign any transfer function here
    //     ownership::as_shared_object_(&mut namespace.id, typed_id, principal, vector::empty(), &auth);

    //     transfer::share_object(namespace);
    // }