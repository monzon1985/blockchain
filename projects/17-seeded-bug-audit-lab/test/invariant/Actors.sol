// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC3156FlashBorrower } from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import { KestrelVault } from "kestrel/KestrelVault.sol";
import { KestrelGovernor } from "kestrel/KestrelGovernor.sol";
import { GovToken } from "shared/GovToken.sol";

/// @notice Generic actor: a contract wallet with no `receive`/`fallback` (many smart wallets and
///         routers cannot take ETH). It executes arbitrary calls for the handler.
contract NoReceiveActor {
    /// @notice Execute `data` against `target` with `msg.value`.
    /// @param target Call target.
    /// @param data Calldata.
    /// @return ok Whether the call succeeded.
    function exec(address target, bytes calldata data) external payable returns (bool ok) {
        (ok,) = target.call{ value: msg.value }(data);
    }
}

/// @notice Generic actor: an integrator contract that holds vault shares and, whenever it
///         receives ETH, reads the vault share price the way any third-party protocol would.
contract PriceObserver {
    /// @notice Vault observed.
    KestrelVault public immutable vault;
    /// @notice Whether the last ETH receipt produced a price read.
    bool public observed;
    /// @notice Price read during the last ETH receipt (assets per 1e18 shares).
    uint256 public observedPrice;

    /// @param _vault Vault observed.
    constructor(KestrelVault _vault) {
        vault = _vault;
    }

    /// @notice Deposit `msg.value` into the vault.
    function deposit() external payable {
        vault.deposit{ value: msg.value }(address(this), 0);
    }

    /// @notice Redeem `shares`, observing the price while the ETH arrives.
    /// @param shares Shares to redeem.
    function redeem(uint256 shares) external {
        observed = false;
        vault.redeem(shares, address(this));
    }

    /// @notice Withdraw `assets`, observing the price while the ETH arrives.
    /// @param assets Wei to withdraw.
    function withdraw(uint256 assets) external {
        observed = false;
        vault.withdraw(assets, address(this));
    }

    /// @notice Integrator hook: read the share price on every ETH receipt.
    receive() external payable {
        try vault.convertToAssets(1e18) returns (uint256 price) {
            observed = true;
            observedPrice = price;
        } catch { }
    }
}

/// @notice Generic ERC-3156 borrower: flash-mints governance tokens and, inside the loan, tries a
///         governance action chosen by the caller, then repays.
contract FlashActor is IERC3156FlashBorrower {
    /// @dev ERC-3156 success value.
    bytes32 private constant CALLBACK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Governance token (also the flash lender).
    GovToken public immutable token;
    /// @notice Governor.
    KestrelGovernor public immutable governor;

    /// @param _token Governance token.
    /// @param _governor Governor.
    constructor(GovToken _token, KestrelGovernor _governor) {
        token = _token;
        governor = _governor;
    }

    /// @notice Flash-borrow `amount` and run `action` inside the loan.
    /// @param amount Tokens to flash-mint.
    /// @param action 0: emergency-execute a treasury transfer; 1: self-delegate first, then the
    ///        same; 2: propose a treasury transfer and vote for it.
    function run(uint256 amount, uint256 action) external {
        token.flashLoan(this, address(token), amount, abi.encode(action));
    }

    /// @inheritdoc IERC3156FlashBorrower
    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        uint256 action = abi.decode(data, (uint256));
        bytes memory transfer =
            abi.encodeCall(IERC20.transfer, (address(this), token.balanceOf(address(governor))));
        if (action == 1) token.delegate(address(this));
        if (action == 2) {
            try governor.propose(address(token), 0, transfer) returns (uint256 id) {
                try governor.castVote(id, true) { } catch { }
            } catch { }
        } else {
            try governor.emergencyExecute(address(token), 0, transfer) { } catch { }
        }
        token.approve(address(token), amount + fee);
        return CALLBACK;
    }
}
