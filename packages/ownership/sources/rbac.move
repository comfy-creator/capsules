// Sui's Role Based Access Control (RBAC) system

// This allows a principal (address) to delegate a set of permissions to an agent (address).
// Roles provide a layer of abstraction; instead of granting each agent a set of permissions individually,
// you assign each agent a set of roles, and then define the permissions for each of those roles.

// A delegation is:
// The specification of a permission (type), enabling access to a set of function calls
// By an agent
// On behalf of the principle

// An RBAC can be used to delegate control of an account
// Example: a game-studio runs a number of servers, and gives their keypairs permissions to edit
// its game objects.

// For safety, we are limiting RBACs to only namespaces for now.
// Previously considered functionality:
// - Allow any user to create an RBAC / namespace so other people can use their account
// - Allow RBAC to be stored inside of objects, and grant permissions to that object on behalf of
// owners.
// We removed this functionality for now because it's too dangerous and complex.
// For simplicity, we limit each agent to having only one role at a time.

// Note that there will never be a permission-vector containing the ADMIN or MANAGER permissions; rather
// you should instead use the grant_admin_role_for_agent() and grant_manager_role_for_agent() functions.
// These give special reserved role-names, as defined in ownership::permissions.

// For safety, this module is only callable by ownership::organization

module ownership::rbac {
    use std::string::String;
    use std::vector;

    use sui::vec_map::{Self, VecMap};

    use sui_utils::vector2;
    use sui_utils::vec_map2;

    use ownership::permissions::{Self, Permission};

    friend ownership::organization;

    // Error enums
    const ENO_PRINCIPAL_AUTHORITY: u64 = 0;

    // Reserved role names
    // const ADMIN_ROLE: vector<u8> = b"ADMIN";
    // const MANAGER_ROLE: vector<u8> = b"MANAGER";

    // After creation the principal cannot be changed
    // This can be modified with mere referential authority; store this somewhere private
    struct RBAC has store, drop {
        principal: address, // permission granted on behalf of
        agent_role: VecMap<address, String>, // agent -> role
        role_permissions: VecMap<String, vector<Permission>> // role -> permissions
    }

    // ======= Principal API =======

    // The principal cannot be changed after creation
    public(friend) fun create(principal: address): RBAC {
        RBAC {
            principal,
            agent_role: vec_map::empty(),
            role_permissions: vec_map::empty()
        }
    }

    // ======= Assign Agents to a Role =======

    // Creates or overwrites existing role for agent
    public(friend) fun set_role_for_agent(rbac: &mut RBAC, agent: address, role: String) {
        vec_map2::set(&mut rbac.agent_role, agent, role);
        // Ensure that role exists in rbac.role_permissions
        vec_map2::borrow_mut_fill(&mut rbac.role_permissions, role, vector::empty());
    }

    // The agent is now indistinguishable from the principal during transaction execution.
    // This is a dangerous role to grant, as the agent can now grant and edit permissions as well
    // Use this with caution.
    // public(friend) fun grant_admin_role_for_agent(rbac: &mut RBAC, agent: address) {
    //     vec_map2::set(&mut rbac.agent_role, agent, utf8(ADMIN_ROLE));
    // }

    // // Grants all permissions, except for admin
    // public(friend) fun grant_manager_role_for_agent(rbac: &mut RBAC, agent: address) {
    //     vec_map2::set(&mut rbac.agent_role, agent, utf8(MANAGER_ROLE));
    // }

    public(friend) fun delete_agent(rbac: &mut RBAC, agent: address) {
        vec_map2::remove_maybe(&mut rbac.agent_role, agent);
    }

    // ======= Assign Permissions to Roles =======

    public(friend) fun grant_permission_to_role<Permission>(rbac: &mut RBAC, role: String) {
        let permission = permissions::new<Permission>();
        if (permissions::is_admin_permission(&permission) || permissions::is_manager_permission(&permission)) {
            // Admin and Manager permissions overwrite all other existing permissions
            vec_map2::set(&mut rbac.role_permissions, role, vector[permission]);
        } else {
            let existing = vec_map2::borrow_mut_fill(&mut rbac.role_permissions, role, vector::empty());
            vector2::merge(existing, vector[permission]);
        };
    }

    // Empty roles (with no permissions) are not automatically deleted
    public(friend) fun revoke_permission_from_role<Permission>(rbac: &mut RBAC, role: String) {
        let permission = permissions::new<Permission>();
        let existing = vec_map2::borrow_mut_fill(&mut rbac.role_permissions, role, vector::empty());
        vector2::remove_maybe(existing, &permission);
    }

    // Any agent with this role will also be removed. The agents can always be re-added with new roles.
    public(friend) fun delete_role_and_agents(rbac: &mut RBAC, role: String) {
        vec_map2::remove_entries_with_value(&mut rbac.agent_role, role);
        vec_map2::remove_maybe(&mut rbac.role_permissions, role);
    }

    // ======= Getter Functions =======

    public(friend) fun to_fields(
        rbac: &RBAC
    ): (address, &VecMap<address, String>, &VecMap<String, vector<Permission>>) {
        (rbac.principal, &rbac.agent_role, &rbac.role_permissions)
    }

    public fun principal(rbac: &RBAC): address {
        rbac.principal
    }

    public fun agent_role(rbac: &RBAC): &VecMap<address, String> {
        &rbac.agent_role
    }

    public(friend) fun role_permissions(rbac: &RBAC): &VecMap<String, vector<Permission>> {
        &rbac.role_permissions
    }

    public(friend) fun get_agent_permissions(rbac: &RBAC, agent: address): vector<Permission> {
        let role = vec_map::get(&rbac.agent_role, &agent);
        *vec_map::get(&rbac.role_permissions, role)
    }
}

    // struct Key has store, copy, drop { principal: address }

    // Used by the principal to create roles and delegate permissions to agents

    // public fun create(principal: address, auth: &TxAuthority): RBAC {
    //     assert!(tx_authority::is_signed_by(principal, auth), ENO_PRINCIPAL_AUTHORITY);

    //     create_internal(principal)
    // }

    // Note that if another rbac is stored in this UID for the same principal, it will be overwritten
    // public fun store(uid: &mut UID, rbac: RBAC) {
    //     dynamic_field2::set(uid, Key { principal: rbac.principal }, rbac);
    // }

    // // Convenience function
    // public fun create_and_store(uid: &mut UID, principal: address, auth: &TxAuthority) {
    //     let rbac = create(principal, auth);
    //     store(uid, rbac);
    // }

    // public fun borrow(): &RBAC {
    // }

    // public fun borrow_mut(): &mut RBAC {
    // }

    // public fun remove(): RBAC {
    // }


    // ======= Agent API =======
    // Used by agents to retrieve their delegated permissions

    // Convenience function. Uses type T as the principal-address
    // public fun claim<T>(uid: &UID, ctx: &TxContext): TxAuthority {
    //     let principal = tx_authority::type_into_address<T>();
    //     let auth = tx_authority::begin(ctx);
    //     claim_(uid, principal, tx_context::sender(ctx), auth)
    // }

    // Auth is passed in here to be added onto, not because it's used as a proof of ownership
    // public fun claim_(uid: &UID, principal: address, agent: address, auth: &TxAuthority): TxAuthority {
    //     if (!dynamic_field::exists_(uid, Key { principal })) { return auth };

    //     let rbac = dynamic_field::borrow<Key, RBAC>(uid, Key { principal });
    //     let roles = vec_map2::get_with_default(&rbac.agent_role, agent, vector::empty());
    //     let i = 0;
    //     while (i < vector::length(roles)) {
    //         let permission = vec_map::get(&rbac.role_permissions, *vector::borrow(roles, i));
    //         auth = tx_authority::add_permissions_internal(principal, permission, &auth);
    //         i = i + 1;
    //     };

    //     auth
    // }

    // This is rather complicated for a validity checker honestly
    // public fun is_allowed_by_owner<T>(uid: &UID, function: u8, auth: &TxAuthority): bool {
    //     let owner_maybe = ownership::get_owner(uid);
    //     if (option::is_none(owner_maybe)) { 
    //         return false // owner is undefined
    //     };
    //     let owner = option::destroy_some(owner_maybe);

    //     // Claim any delegations that may be waiting for us inside inside of this UID
    //     let i = 0;
    //     let agents = tx_authority::agents(auth);
    //     while (i < vector::length(&agents)) {
    //         let agent = *vector::borrow(&agents, i);
    //         auth = claim_(uid, owner, agent, auth);
    //         i = i + 1;
    //     };

    //     // The owner is a signer, or a delegation from the owner for this function already exists within `auth`
    //     tx_authority::is_allowed<T>(owner, function, auth)
    // }