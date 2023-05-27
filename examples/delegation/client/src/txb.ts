import { TransactionArgument, TransactionBlock } from "@mysten/sui.js";
import { babyPackageId, ownerKeypair, ownerSigner, ownershipPackageId } from "./config";

interface EditBabyNameOptions {
  baby: TransactionArgument | string;
  auth: TransactionArgument;
  newName: string;
}

interface BabyDelegationOptions {
  store: TransactionArgument | string;
  auth: TransactionArgument;
  babyId: string;
  agent: string;
}

interface AddOrganizationPackageOptions {
  receipt: string;
  auth: TransactionArgument;
  organization: TransactionArgument | string;
}

interface DestroyOrganizationOptions {
  auth: TransactionArgument;
  organization: TransactionArgument | string;
}

interface RemoveOrganizationPackageOptions {
  packageId: string;
  auth: TransactionArgument;
  organization: TransactionArgument | string;
}

export function createDelegationStore(txb: TransactionBlock) {
  return txb.moveCall({
    arguments: [],
    typeArguments: [],
    target: `${ownershipPackageId}::delegation::create`,
  });
}

export function returnAndShareDelegationStore(txb: TransactionBlock, store: TransactionArgument) {
  return txb.moveCall({
    typeArguments: [],
    target: `${ownershipPackageId}::delegation::return_and_share`,
    arguments: [store],
  });
}

export function beginTxAuth(txb: TransactionBlock) {
  return txb.moveCall({
    arguments: [],
    typeArguments: [],
    target: `${ownershipPackageId}::tx_authority::begin`,
  });
}

export function claimDelegation(txb: TransactionBlock, store: TransactionArgument | string) {
  return txb.moveCall({
    typeArguments: [],
    target: `${ownershipPackageId}::delegation::claim_delegation`,
    arguments: [typeof store == "string" ? txb.object(store) : store],
  });
}

export function delegateBaby(txb: TransactionBlock, { auth, store, agent, babyId }: BabyDelegationOptions) {
  return txb.moveCall({
    typeArguments: [`${babyPackageId}::capsule_baby::EDITOR`],
    target: `${ownershipPackageId}::delegation::add_permission_for_objects`,
    arguments: [typeof store == "string" ? txb.object(store) : store, txb.pure(agent), txb.pure([babyId]), auth],
  });
}

export function undelegateBaby(txb: TransactionBlock, { auth, store, agent, babyId }: BabyDelegationOptions) {
  return txb.moveCall({
    typeArguments: [`${babyPackageId}::capsule_baby::EDITOR`],
    target: `${ownershipPackageId}::delegation::add_permission_for_objects`,
    arguments: [typeof store == "string" ? txb.object(store) : store, txb.pure(agent), txb.pure([babyId]), auth],
  });
}

export function createCapsuleBaby(txb: TransactionBlock, name: string) {
  return txb.moveCall({
    arguments: [txb.pure(name)],
    target: `${babyPackageId}::capsule_baby::create_baby`,
    typeArguments: [],
  });
}

export function returnAndShareCapsuleBaby(txb: TransactionBlock, baby: TransactionArgument) {
  return txb.moveCall({
    arguments: [baby],
    target: `${babyPackageId}::capsule_baby::return_and_share`,
    typeArguments: [],
  });
}

export function editCapsuleBabyName(txb: TransactionBlock, { auth, baby, newName }: EditBabyNameOptions) {
  return txb.moveCall({
    arguments: [typeof baby == "string" ? txb.object(baby) : baby, txb.pure(newName), auth],
    target: `${babyPackageId}::capsule_baby::edit_baby_name`,
    typeArguments: [],
  });
}

export function createOrganizationFromPublishReceipt(txb: TransactionBlock, receipt: string) {
  let owner = ownerKeypair.getPublicKey().toSuiAddress();

  return txb.moveCall({
    arguments: [txb.object(receipt), txb.pure(owner)],
    target: `${ownershipPackageId}::organization::create_from_receipt`,
    typeArguments: [],
  });
}

export function addOrganizationPackage(
  txb: TransactionBlock,
  { auth, receipt, organization }: AddOrganizationPackageOptions
) {
  return txb.moveCall({
    arguments: [txb.object(receipt), typeof organization == "string" ? txb.object(organization) : organization, auth],
    target: `${ownershipPackageId}::organization::add_package`,
    typeArguments: [],
  });
}

export function removeOrganizationPackage(
  txb: TransactionBlock,
  { auth, packageId, organization }: RemoveOrganizationPackageOptions
) {
  return txb.moveCall({
    arguments: [typeof organization == "string" ? txb.object(organization) : organization, txb.pure(packageId), auth],
    target: `${ownershipPackageId}::organization::remove_package`,
    typeArguments: [],
  });
}

export function destroyOrganization(txb: TransactionBlock, { auth, organization }: DestroyOrganizationOptions) {
  return txb.moveCall({
    arguments: [typeof organization == "string" ? txb.object(organization) : organization, auth],
    target: `${ownershipPackageId}::organization::destroy`,
    typeArguments: [],
  });
}

export function returnAndShareOrganization(txb: TransactionBlock, organization: TransactionArgument) {
  return txb.moveCall({
    arguments: [organization],
    target: `${ownershipPackageId}::organization::return_and_share`,
    typeArguments: [],
  });
}