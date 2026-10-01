// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin-contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin-contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin-contracts/access/Ownable2Step.sol";

/// @title FixtureToken
/// @notice ERC-20 that generates indexable traffic on a local devnet for the reorg-safe indexer's
///         integration tests. The owner mints, any holder burns its own balance, and
///         `batchTransfer` fans many `Transfer` logs out of a single transaction so tests can
///         push `eth_getLogs` past provider result limits.
/// @dev A test fixture, never deployed with value. Every balance change goes through OpenZeppelin's
///      `_update`, so every change emits exactly one `Transfer` event: the invariant the indexer's
///      balance derivation depends on.
contract FixtureToken is ERC20, Ownable2Step {
    /// @notice `batchTransfer` was called with arrays of different lengths.
    /// @param recipients Length of the recipients array.
    /// @param amounts Length of the amounts array.
    error LengthMismatch(uint256 recipients, uint256 amounts);

    /// @notice `batchTransfer` was called with no recipients.
    error EmptyBatch();

    /// @notice Number of decimals reported by `decimals()`, fixed at deployment.
    // Slither wants mixedCase for variables; `forge lint` wants SCREAMING_SNAKE_CASE for immutables.
    // The two conflict here, and the Foundry convention wins.
    // slither-disable-next-line naming-convention
    uint8 private immutable DECIMALS;

    /// @notice Deploys the token.
    /// @param name_ ERC-20 name.
    /// @param symbol_ ERC-20 symbol.
    /// @param decimals_ Value returned by `decimals()` (the vault fixture inherits it plus its offset).
    /// @param owner_ Account allowed to mint.
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address owner_)
        ERC20(name_, symbol_)
        Ownable(owner_)
    {
        DECIMALS = decimals_;
    }

    /// @notice Mints `amount` tokens to `to`, emitting `Transfer(address(0), to, amount)`.
    /// @dev Reverts with `OwnableUnauthorizedAccount` for any caller other than the owner, and with
    ///      `ERC20InvalidReceiver` for the zero address.
    /// @param to Recipient of the new tokens.
    /// @param amount Amount minted, in base units.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burns `amount` of the caller's tokens, emitting `Transfer(msg.sender, address(0), amount)`.
    /// @param amount Amount burned, in base units.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Transfers `amounts[i]` to `recipients[i]` for every `i`, emitting one `Transfer` per pair.
    /// @dev Stops at the first failing leg (the whole transaction reverts), so a successful call emits
    ///      exactly `recipients.length` logs.
    /// @param recipients Accounts receiving tokens.
    /// @param amounts Amount for each recipient, in base units.
    /// @return True, mirroring `transfer`.
    function batchTransfer(address[] calldata recipients, uint256[] calldata amounts)
        external
        returns (bool)
    {
        uint256 n = recipients.length;
        require(n != 0, EmptyBatch());
        require(n == amounts.length, LengthMismatch(n, amounts.length));
        for (uint256 i; i < n; ++i) {
            _transfer(msg.sender, recipients[i], amounts[i]);
        }
        return true;
    }

    /// @notice Token decimals, fixed at deployment.
    /// @return The decimals passed to the constructor.
    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }
}
