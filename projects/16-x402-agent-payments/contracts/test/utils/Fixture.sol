// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {AgentAccount} from "../../src/account/AgentAccount.sol";
import {AgentAccountFactory} from "../../src/account/AgentAccountFactory.sol";
import {PaymentEscrow} from "../../src/escrow/PaymentEscrow.sol";
import {BudgetExecutor} from "../../src/modules/BudgetExecutor.sol";
import {IdentityRegistry} from "../../src/registry/IdentityRegistry.sol";
import {ReputationRegistry} from "../../src/registry/ReputationRegistry.sol";
import {ValidationRegistry} from "../../src/registry/ValidationRegistry.sol";
import {ResourceBinding} from "../../src/settlement/ResourceBinding.sol";
import {SettlementLog} from "../../src/settlement/SettlementLog.sol";
import {TestUSD} from "../../src/token/TestUSD.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Shared deployment and signing helpers for every Foundry suite.
abstract contract Fixture is Test {
    bytes32 internal constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 internal constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint256 internal constant T0 = 1_750_000_000;
    uint256 internal constant ONE = 1e6; // 1 tUSD
    bytes32 internal constant RESOURCE = keccak256("POST http://127.0.0.1/api/v1/sentiment#body=0xabc");
    bytes32 internal constant OTHER_RESOURCE = keccak256("POST http://127.0.0.1/api/v1/keywords#body=0xabc");

    TestUSD internal token;
    SettlementLog internal settlement;
    BudgetExecutor internal executor;
    PaymentEscrow internal escrow;
    AgentAccountFactory internal factory;
    IdentityRegistry internal identity;
    ReputationRegistry internal reputation;
    ValidationRegistry internal validation;

    address internal deployer = makeAddr("deployer");
    address internal payee = makeAddr("payee");
    address internal otherPayee = makeAddr("otherPayee");
    address internal relayer = makeAddr("relayer");

    uint256 internal payerKey;
    address internal payer;
    uint256 internal ownerKey;
    address internal owner;
    uint256 internal sessionKey;
    address internal session;

    function setUp() public virtual {
        vm.warp(T0);
        (payer, payerKey) = makeAddrAndKey("payer");
        (owner, ownerKey) = makeAddrAndKey("owner");
        (session, sessionKey) = makeAddrAndKey("session");

        vm.startPrank(deployer);
        token = new TestUSD(deployer);
        settlement = new SettlementLog(address(token), deployer);
        executor = new BudgetExecutor(settlement);
        escrow = new PaymentEscrow(settlement);
        factory = new AgentAccountFactory(address(executor));
        identity = new IdentityRegistry();
        reputation = new ReputationRegistry(identity, settlement);
        validation = new ValidationRegistry(identity);
        settlement.setRecorder(address(executor), true);
        settlement.setRecorder(address(escrow), true);
        settlement.seal();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- token helpers

    function _mint(address to, uint256 amount) internal {
        vm.prank(deployer);
        token.mint(to, amount);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _authDigest(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(
            token.DOMAIN_SEPARATOR(), keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce))
        );
    }

    /// @dev Builds and signs an `exact` authorization bound to `resourceHash`.
    function _exactAuth(uint256 key, address to, uint256 value, bytes32 resourceHash, bytes32 salt)
        internal
        view
        returns (SettlementLog.ExactAuthorization memory auth, bytes memory sig)
    {
        auth = SettlementLog.ExactAuthorization({
            from: vm.addr(key),
            to: to,
            value: value,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 120,
            nonce: ResourceBinding.exactNonce(resourceHash, salt)
        });
        sig = _sign(
            key,
            _authDigest(
                TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                auth.from,
                auth.to,
                auth.value,
                auth.validAfter,
                auth.validBefore,
                auth.nonce
            )
        );
    }

    /// @dev Settles an `exact` payment from `payer` to `payee` and returns its receipt id.
    function _settleExact(uint256 value, bytes32 resourceHash, bytes32 salt) internal returns (bytes32) {
        (SettlementLog.ExactAuthorization memory auth, bytes memory sig) =
            _exactAuth(payerKey, payee, value, resourceHash, salt);
        vm.prank(relayer);
        return settlement.settleExact(auth, resourceHash, salt, sig);
    }

    // ---------------------------------------------------------------- escrow helpers

    function _escrowRequest(uint256 key, address to, uint256 value, bytes32 resourceHash, uint64 deadline, bytes32 salt)
        internal
        view
        returns (PaymentEscrow.OpenRequest memory r, bytes memory sig)
    {
        r = PaymentEscrow.OpenRequest({
            from: vm.addr(key),
            value: value,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 120,
            nonce: ResourceBinding.escrowNonce(to, resourceHash, deadline, salt),
            payee: to,
            resourceHash: resourceHash,
            deliveryDeadline: deadline,
            salt: salt
        });
        sig = _sign(
            key,
            _authDigest(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                r.from,
                address(escrow),
                r.value,
                r.validAfter,
                r.validBefore,
                r.nonce
            )
        );
    }

    // ---------------------------------------------------------------- budget helpers

    function _policy(uint128 cap, uint128 budget, uint32 period, uint16 maxPayments)
        internal
        view
        returns (BudgetExecutor.Policy memory)
    {
        return BudgetExecutor.Policy({
            sessionKey: session,
            validUntil: uint48(block.timestamp + 30 days),
            period: period,
            maxPaymentsPerPeriod: maxPayments,
            perCallCap: cap,
            periodBudget: budget
        });
    }

    function _defaultPolicy() internal view returns (BudgetExecutor.Policy memory) {
        return _policy(uint128(ONE), uint128(5 * ONE), 1 hours, 16);
    }

    function _payees() internal view returns (address[] memory list) {
        list = new address[](2);
        list[0] = payee;
        list[1] = otherPayee;
    }

    function _createAccount(BudgetExecutor.Policy memory policy, address[] memory payees)
        internal
        returns (AgentAccount account)
    {
        account = AgentAccount(payable(factory.createAccount(owner, abi.encode(policy, payees), bytes32(0))));
    }

    function _intent(address account, address to, uint256 amount, bytes32 resourceHash, bytes32 nonce)
        internal
        view
        returns (BudgetExecutor.PaymentIntent memory)
    {
        return BudgetExecutor.PaymentIntent({
            account: account,
            payee: to,
            amount: amount,
            resourceHash: resourceHash,
            nonce: nonce,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 120
        });
    }

    function _signIntent(uint256 key, BudgetExecutor.PaymentIntent memory intent) internal view returns (bytes memory) {
        return _sign(key, executor.hashPaymentIntent(intent));
    }

    function _pay(address account, address to, uint256 amount, bytes32 nonce) internal returns (bytes32) {
        BudgetExecutor.PaymentIntent memory intent = _intent(account, to, amount, RESOURCE, nonce);
        bytes memory sig = _signIntent(sessionKey, intent);
        vm.prank(relayer);
        return executor.pay(intent, sig);
    }

    // ---------------------------------------------------------------- ERC-7739

    /// @dev Produces an ERC-7739 nested typed-data signature of `ownerKey_` for `account`, over an app message whose
    ///      EIP-712 domain separator is `appSeparator`, struct hash `contentsHash` and type string `contentsType`.
    function _erc7739Sign(
        uint256 ownerKey_,
        AgentAccount account,
        bytes32 appSeparator,
        bytes32 contentsHash,
        string memory contentsName,
        string memory contentsType
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encodePacked(
                _typedDataSignTypehash(contentsName, contentsType), contentsHash, _accountDomainBytes(account)
            )
        );
        bytes memory inner = _sign(ownerKey_, MessageHashUtils.toTypedDataHash(appSeparator, structHash));
        return abi.encodePacked(inner, appSeparator, contentsHash, contentsType, uint16(bytes(contentsType).length));
    }

    function _typedDataSignTypehash(string memory contentsName, string memory contentsType)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "TypedDataSign(",
                contentsName,
                " contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)",
                contentsType
            )
        );
    }

    function _accountDomainBytes(AgentAccount account) internal view returns (bytes memory) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract, bytes32 salt,) =
            account.eip712Domain();
        return abi.encode(keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract, salt);
    }

    function _domainSeparator(address target) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            IEIP712Domain(target).eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }
}

interface IEIP712Domain {
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}
