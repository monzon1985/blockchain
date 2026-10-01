// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AccessManaged} from "@openzeppelin-contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin-contracts/utils/math/SafeCast.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IComplianceEngine, IComplianceModule, TransferContext, TransferKind} from "../interfaces/ICompliance.sol";

/// @title ComplianceEngine
/// @notice Modular compliance for the fund share (ERC-3643 `ModularCompliance` equivalent). The token calls
///         `transferred` inside its single `_update` choke point for every balance movement: transfers, 7540
///         claims (mints), redemption requests (burns), forced transfers and recoveries. The engine runs every
///         module's check, then records the movement in its investor ledger and in stateful modules.
/// @dev The investor ledger fixes a classic ERC-3643 bookkeeping bug. Holder counts are per investor
///      identity (not per wallet), and both the wallet -> identity binding and the identity -> country
///      attribution are snapshotted when a wallet / identity starts holding. Later registry changes (wallet
///      rebinding, a new jurisdiction claim) therefore cannot make the decrement hit a different bucket than
///      the increment, which keeps `holderCount` exact under partial transfers, freezes and recoveries.
contract ComplianceEngine is AccessManaged, IComplianceEngine {
    using SafeCast for uint256;

    /// @notice Maximum number of plugged modules; bounds the per-transfer loop.
    uint256 public constant MAX_MODULES = 8;

    /// @dev One slot per module: address + whether it wants `onTransfer` callbacks.
    struct ModuleEntry {
        address module;
        bool stateful;
    }

    /// @dev Per-identity ledger entry: aggregate balance and the country attributed while holding.
    struct Investor {
        uint240 balance;
        uint16 country;
    }

    /// @notice Registry used to resolve wallets that do not hold yet and to attribute countries.
    IIdentityRegistry public immutable identityRegistry;

    /// @notice The only token allowed to report movements; bound once by governance.
    address public token;

    /// @notice Number of investors with a positive balance, all countries.
    uint256 public totalHolders;

    /// @notice Sum of all investor balances; equals the token's total supply.
    uint256 public trackedSupply;

    /// @dev Plugged modules, in check order.
    ModuleEntry[] private _modules;

    /// @dev Identity snapshot of each wallet while its balance is positive.
    mapping(address wallet => bytes32 identity) private _walletIdentity;

    /// @dev Investor ledger.
    mapping(bytes32 identity => Investor) private _investors;

    /// @dev Investors with a positive balance per country.
    mapping(uint16 country => uint256 count) private _holderCount;

    /// @notice Emitted once when the token is bound.
    /// @param token Token address.
    event TokenBound(address indexed token);
    /// @notice Emitted when a module is plugged in.
    /// @param module Module.
    /// @param stateful Whether it receives `onTransfer` callbacks.
    event ModuleAdded(address indexed module, bool stateful);
    /// @notice Emitted when a module is unplugged.
    /// @param module Module.
    event ModuleRemoved(address indexed module);
    /// @notice Emitted when an investor's aggregate balance becomes positive.
    /// @param identity Investor.
    /// @param country Country the investor is counted under until it exits.
    /// @param countryHolders Holder count of `country` after the change.
    event InvestorEntered(bytes32 indexed identity, uint16 indexed country, uint256 countryHolders);
    /// @notice Emitted when an investor's aggregate balance drops to zero.
    /// @param identity Investor.
    /// @param country Country the investor was counted under.
    /// @param countryHolders Holder count of `country` after the change.
    event InvestorExited(bytes32 indexed identity, uint16 indexed country, uint256 countryHolders);

    /// @notice Caller is not the bound token.
    error NotToken(address caller);
    /// @notice Token already bound, or zero token.
    error TokenAlreadyBound(address token);
    /// @notice Module is bound to another engine.
    error ModuleEngineMismatch(address module, address moduleEngine);
    /// @notice Module already plugged.
    error ModuleAlreadyAdded(address module);
    /// @notice Module not plugged.
    error ModuleNotFound(address module);
    /// @notice `MAX_MODULES` reached.
    error TooManyModules(uint256 max);
    /// @notice A module rejected the movement.
    error ComplianceModuleRejected(address module, TransferKind kind, address from, address to, uint256 amount);
    /// @notice The recipient does not resolve to an identity.
    error RecipientWithoutIdentity(address to);

    /// @param initialAuthority AccessManager governing restricted functions.
    /// @param registry Identity registry.
    constructor(address initialAuthority, IIdentityRegistry registry) AccessManaged(initialAuthority) {
        identityRegistry = registry;
    }

    /// @notice Binds the share token. One-shot.
    /// @param token_ Token address.
    function bindToken(address token_) external restricted {
        require(token == address(0) && token_ != address(0), TokenAlreadyBound(token));
        token = token_;
        emit TokenBound(token_);
    }

    /// @notice Plugs `module` in. It must be bound to this engine.
    /// @param module Module address.
    function addModule(address module) external restricted {
        address moduleEngine = IComplianceModule(module).engine();
        require(moduleEngine == address(this), ModuleEngineMismatch(module, moduleEngine));
        uint256 length = _modules.length;
        require(length < MAX_MODULES, TooManyModules(MAX_MODULES));
        for (uint256 i; i < length; ++i) {
            require(_modules[i].module != module, ModuleAlreadyAdded(module));
        }
        bool stateful = IComplianceModule(module).isStateful();
        _modules.push(ModuleEntry({module: module, stateful: stateful}));
        emit ModuleAdded(module, stateful);
    }

    /// @notice Unplugs `module`. Order of the remaining modules may change.
    /// @param module Module address.
    function removeModule(address module) external restricted {
        uint256 length = _modules.length;
        for (uint256 i; i < length; ++i) {
            if (_modules[i].module == module) {
                _modules[i] = _modules[length - 1];
                _modules.pop();
                emit ModuleRemoved(module);
                return;
            }
        }
        revert ModuleNotFound(module);
    }

    /// @inheritdoc IComplianceEngine
    function transferred(TransferKind kind, address from, address to, uint256 amount) external {
        require(msg.sender == token, NotToken(msg.sender));
        TransferContext memory ctx = _buildContext(kind, from, to, amount);
        require(to == address(0) || ctx.toId != bytes32(0), RecipientWithoutIdentity(to));

        uint256 length = _modules.length;
        for (uint256 i; i < length; ++i) {
            address module = _modules[i].module;
            require(IComplianceModule(module).check(ctx), ComplianceModuleRejected(module, kind, from, to, amount));
        }

        if (amount != 0) _record(ctx);

        for (uint256 i; i < length; ++i) {
            ModuleEntry memory entry = _modules[i];
            if (entry.stateful) IComplianceModule(entry.module).onTransfer(ctx);
        }
    }

    /// @inheritdoc IComplianceEngine
    function checkTransfer(TransferKind kind, address from, address to, uint256 amount)
        external
        view
        returns (bool allowed, address rejectedBy)
    {
        TransferContext memory ctx = _buildContext(kind, from, to, amount);
        if (to != address(0) && ctx.toId == bytes32(0)) return (allowed, rejectedBy);
        uint256 length = _modules.length;
        for (uint256 i; i < length; ++i) {
            address module = _modules[i].module;
            if (!IComplianceModule(module).check(ctx)) return (allowed, module);
        }
        allowed = true;
    }

    /// @notice Context the engine would hand to modules for a movement (for off-chain simulation).
    /// @param kind Movement category.
    /// @param from Sender.
    /// @param to Recipient.
    /// @param amount Amount.
    /// @return ctx The context.
    function previewContext(TransferKind kind, address from, address to, uint256 amount)
        external
        view
        returns (TransferContext memory ctx)
    {
        return _buildContext(kind, from, to, amount);
    }

    /// @notice Plugged modules in check order.
    /// @return modules Module addresses.
    function getModules() external view returns (address[] memory modules) {
        uint256 length = _modules.length;
        modules = new address[](length);
        for (uint256 i; i < length; ++i) {
            modules[i] = _modules[i].module;
        }
    }

    /// @inheritdoc IComplianceEngine
    function resolveIdentity(address wallet) public view returns (bytes32 identity) {
        identity = _walletIdentity[wallet];
        if (identity == bytes32(0)) identity = identityRegistry.identityOf(wallet);
    }

    /// @notice Identity snapshot of `wallet` (zero unless it currently holds shares).
    /// @param wallet Wallet.
    /// @return Identity snapshot.
    function walletIdentity(address wallet) external view returns (bytes32) {
        return _walletIdentity[wallet];
    }

    /// @inheritdoc IComplianceEngine
    function investorBalance(bytes32 identity) external view returns (uint256) {
        return _investors[identity].balance;
    }

    /// @notice Country `identity` is counted under (meaningful while its balance is positive).
    /// @param identity Investor.
    /// @return Country code snapshot.
    function investorCountry(bytes32 identity) external view returns (uint16) {
        return _investors[identity].country;
    }

    /// @inheritdoc IComplianceEngine
    function holderCount(uint16 country) external view returns (uint256) {
        return _holderCount[country];
    }

    function _buildContext(TransferKind kind, address from, address to, uint256 amount)
        private
        view
        returns (TransferContext memory ctx)
    {
        ctx.kind = kind;
        ctx.from = from;
        ctx.to = to;
        ctx.amount = amount;
        if (from != address(0)) {
            ctx.fromId = resolveIdentity(from);
            ctx.fromBalance = IERC20(token).balanceOf(from);
        }
        if (to != address(0)) ctx.toId = resolveIdentity(to);

        bool sameInvestor = ctx.fromId == ctx.toId && from != address(0) && to != address(0);
        if (amount == 0 || sameInvestor) {
            // No investor-level change: only country snapshots are informative.
            ctx.fromCountry = _investors[ctx.fromId].country;
            ctx.toCountry = _investors[ctx.toId].country;
            ctx.toInvestorBalance = _investors[ctx.toId].balance;
            return ctx;
        }
        if (from != address(0)) {
            Investor storage sender = _investors[ctx.fromId];
            ctx.fromCountry = sender.country;
            ctx.fromLeavesHolders = sender.balance == amount;
        }
        if (to != address(0)) {
            Investor storage receiver = _investors[ctx.toId];
            ctx.toInvestorBalance = receiver.balance;
            ctx.toBecomesHolder = receiver.balance == 0;
            ctx.toCountry = ctx.toBecomesHolder ? identityRegistry.investorCountry(ctx.toId) : receiver.country;
        }
    }

    function _record(TransferContext memory ctx) private {
        bool sameInvestor = ctx.fromId == ctx.toId && ctx.from != address(0) && ctx.to != address(0);

        if (ctx.from != address(0)) {
            if (ctx.fromBalance == ctx.amount) delete _walletIdentity[ctx.from];
            if (!sameInvestor) {
                Investor storage sender = _investors[ctx.fromId];
                sender.balance -= ctx.amount.toUint240();
                if (ctx.fromLeavesHolders) {
                    uint256 remaining = --_holderCount[ctx.fromCountry];
                    --totalHolders;
                    emit InvestorExited(ctx.fromId, ctx.fromCountry, remaining);
                }
            }
        } else {
            trackedSupply += ctx.amount;
        }

        if (ctx.to != address(0)) {
            if (_walletIdentity[ctx.to] == bytes32(0)) _walletIdentity[ctx.to] = ctx.toId;
            if (!sameInvestor) {
                Investor storage receiver = _investors[ctx.toId];
                if (ctx.toBecomesHolder) {
                    receiver.country = ctx.toCountry;
                    uint256 count = ++_holderCount[ctx.toCountry];
                    ++totalHolders;
                    emit InvestorEntered(ctx.toId, ctx.toCountry, count);
                }
                receiver.balance += ctx.amount.toUint240();
            }
        } else {
            trackedSupply -= ctx.amount;
        }
    }
}
