import { VecMap } from "../../_dependencies/source/0x2/vec-map/structs"
import { bcsSource as bcs } from "../../_framework/bcs"
import { FieldsWithTypes, Type } from "../../_framework/util"
import { ActionSet } from "../action-set/structs"
import { Encoding } from "@mysten/bcs"
import { ObjectId } from "@mysten/sui.js"

/* ============================== TxAuthority =============================== */

bcs.registerStructType(
    "0x98eff0617dfece5a417af4e2d2338afdfc5124e35a337c530161e8f3d7ac3e96::tx_authority::TxAuthority",
    {
        principal_actions: `0x2::vec_map::VecMap<address, 0x98eff0617dfece5a417af4e2d2338afdfc5124e35a337c530161e8f3d7ac3e96::action_set::ActionSet>`,
        package_org: `0x2::vec_map::VecMap<0x2::object::ID, address>`,
    }
)

export function isTxAuthority(type: Type): boolean {
    return (
        type ===
        "0x98eff0617dfece5a417af4e2d2338afdfc5124e35a337c530161e8f3d7ac3e96::tx_authority::TxAuthority"
    )
}

export interface TxAuthorityFields {
    principalActions: VecMap<string, ActionSet>
    packageOrg: VecMap<ObjectId, string>
}

export class TxAuthority {
    static readonly $typeName =
        "0x98eff0617dfece5a417af4e2d2338afdfc5124e35a337c530161e8f3d7ac3e96::tx_authority::TxAuthority"
    static readonly $numTypeParams = 0

    readonly principalActions: VecMap<string, ActionSet>
    readonly packageOrg: VecMap<ObjectId, string>

    constructor(fields: TxAuthorityFields) {
        this.principalActions = fields.principalActions
        this.packageOrg = fields.packageOrg
    }

    static fromFields(fields: Record<string, any>): TxAuthority {
        return new TxAuthority({
            principalActions: VecMap.fromFields<string, ActionSet>(
                [
                    `address`,
                    `0x98eff0617dfece5a417af4e2d2338afdfc5124e35a337c530161e8f3d7ac3e96::action_set::ActionSet`,
                ],
                fields.principal_actions
            ),
            packageOrg: VecMap.fromFields<ObjectId, string>(
                [`0x2::object::ID`, `address`],
                fields.package_org
            ),
        })
    }

    static fromFieldsWithTypes(item: FieldsWithTypes): TxAuthority {
        if (!isTxAuthority(item.type)) {
            throw new Error("not a TxAuthority type")
        }
        return new TxAuthority({
            principalActions: VecMap.fromFieldsWithTypes<string, ActionSet>(
                item.fields.principal_actions
            ),
            packageOrg: VecMap.fromFieldsWithTypes<ObjectId, string>(item.fields.package_org),
        })
    }

    static fromBcs(data: Uint8Array | string, encoding?: Encoding): TxAuthority {
        return TxAuthority.fromFields(bcs.de([TxAuthority.$typeName], data, encoding))
    }
}