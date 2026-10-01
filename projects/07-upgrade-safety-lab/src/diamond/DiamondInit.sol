// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IRegistryErrors, IRegistryEvents} from "../interfaces/IRegistry.sol";
import {IDiamondCut, IDiamondLoupe} from "./interfaces/IDiamond.sol";
import {LibDiamond} from "./libraries/LibDiamond.sol";
import {LibRegistryDiamond} from "./libraries/LibRegistryDiamond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title DiamondInit
/// @notice One-shot initializer delegatecalled by the constructor cut (ERC-2535 `_init`). It is never registered
///         as a facet, so it can only run inside a `diamondCut`.
contract DiamondInit is IRegistryEvents, IRegistryErrors {
    /// @notice The diamond's payments were already configured.
    /// @param token The token already in place.
    error AlreadyInitialized(address token);

    /// @notice Registers the ERC-165 interfaces and configures payments.
    /// @param token ERC-20 token subscribers pay in.
    /// @param initialTreasury Account that receives payments.
    function init(IERC20 token, address initialTreasury) external {
        LibRegistryDiamond.RegistryStorage storage $ = LibRegistryDiamond.registryStorage();
        if (address($.paymentToken) != address(0)) revert AlreadyInitialized(address($.paymentToken));
        if (address(token).code.length == 0) revert InvalidPaymentToken(address(token));
        if (initialTreasury == address(0)) revert InvalidTreasury(address(0));

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;

        $.paymentToken = token;
        $.treasury = initialTreasury;
        emit PaymentsConfigured(address(token), initialTreasury);
    }
}
