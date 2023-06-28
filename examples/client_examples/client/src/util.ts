import { SuiTransactionBlockResponse } from "@mysten/sui.js";
import { provider } from "./config";

export async function createdObjects(txb: SuiTransactionBlockResponse) {
  if (!txb.effects?.created) throw new Error("");

  const objects = new Map();
  const ids = txb.effects.created.map((obj) => obj.reference.objectId);
  const multiObjects = await provider.multiGetObjects({ ids, options: { showType: true } });

  for (let i = 0; i < multiObjects.length; i++) {
    const object = multiObjects[i];
    objects.set(object.data.type, object.data.objectId);
  }

  return objects;
}