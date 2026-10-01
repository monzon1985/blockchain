// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ComplianceModuleBase} from "./ComplianceModuleBase.sol";
import {IComplianceEngine, IComplianceModule, TransferContext} from "../../interfaces/ICompliance.sol";

/// @title MaxHoldersPerCountryModule
/// @notice Caps the number of investors (identities, not wallets) per country, plus an optional fund-wide cap.
/// @dev Reads the engine's snapshot-based holder counts, so a recipient that becomes a holder is admitted only
///      if its country still has room. A movement where the sender's investor fully exits and the recipient's
///      investor enters the same country is net-zero and allowed at the cap. Lowering a cap below the current
///      count keeps existing holders and blocks new ones until the count drops.
contract MaxHoldersPerCountryModule is ComplianceModuleBase {
    /// @dev Cap configuration; `capped == false` means unlimited.
    struct Cap {
        bool capped;
        uint64 limit;
    }

    /// @notice Per-country cap (ISO 3166-1 numeric code).
    mapping(uint16 country => Cap) public countryCap;

    /// @notice Fund-wide cap across all countries.
    Cap public globalCap;

    /// @notice Emitted when the cap of `country` changes.
    /// @param country Country.
    /// @param capped Whether a cap applies.
    /// @param limit Maximum holders when capped.
    event CountryCapSet(uint16 indexed country, bool capped, uint64 limit);
    /// @notice Emitted when the fund-wide cap changes.
    /// @param capped Whether a cap applies.
    /// @param limit Maximum holders when capped.
    event GlobalCapSet(bool capped, uint64 limit);

    /// @param initialAuthority AccessManager.
    /// @param engine_ Compliance engine.
    constructor(address initialAuthority, address engine_) ComplianceModuleBase(initialAuthority, engine_) {}

    /// @notice Caps `country` at `limit` investors (0 bans new holders from it).
    /// @param country Country.
    /// @param limit Maximum holders.
    function setCountryCap(uint16 country, uint64 limit) external restricted {
        countryCap[country] = Cap({capped: true, limit: limit});
        emit CountryCapSet(country, true, limit);
    }

    /// @notice Removes the cap of `country`.
    /// @param country Country.
    function clearCountryCap(uint16 country) external restricted {
        delete countryCap[country];
        emit CountryCapSet(country, false, 0);
    }

    /// @notice Sets (or clears, with `capped == false`) the fund-wide holder cap.
    /// @param capped Whether a cap applies.
    /// @param limit Maximum holders.
    function setGlobalCap(bool capped, uint64 limit) external restricted {
        globalCap = Cap({capped: capped, limit: capped ? limit : 0});
        emit GlobalCapSet(capped, capped ? limit : 0);
    }

    /// @inheritdoc IComplianceModule
    function name() external pure returns (string memory) {
        return "MaxHoldersPerCountry";
    }

    /// @inheritdoc IComplianceModule
    function check(TransferContext calldata ctx) external view returns (bool) {
        if (!ctx.toBecomesHolder) return true;

        Cap memory cap = countryCap[ctx.toCountry];
        if (cap.capped) {
            uint256 current = IComplianceEngine(engine).holderCount(ctx.toCountry);
            if (ctx.fromLeavesHolders && ctx.fromCountry == ctx.toCountry) --current;
            if (current + 1 > cap.limit) return false;
        }

        Cap memory global = globalCap;
        if (global.capped) {
            uint256 total = IComplianceEngine(engine).totalHolders();
            if (ctx.fromLeavesHolders) --total;
            if (total + 1 > global.limit) return false;
        }
        return true;
    }
}
