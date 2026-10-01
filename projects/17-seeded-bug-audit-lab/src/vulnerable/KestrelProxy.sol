// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title KestrelProxy
/// @notice Hand-rolled transparent upgradeable proxy in front of {KestrelConfig}. The admin
///         reaches only the proxy's own admin functions; every other caller is delegated to the
///         implementation, so proxy selectors never shadow implementation selectors.
/// @dev    The implementation address lives at the EIP-1967 implementation slot.
contract KestrelProxy {
    /// @notice EIP-1967 implementation slot: `keccak256("eip1967.proxy.implementation") - 1`.
    bytes32 private constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The proxy administrator.
    address private _admin;

    /// @notice Emitted when the implementation changes.
    /// @param implementation The new implementation.
    event Upgraded(address indexed implementation);
    /// @notice Emitted when the admin changes.
    /// @param previousAdmin The previous admin.
    /// @param newAdmin The new admin.
    event AdminChanged(address previousAdmin, address newAdmin);

    /// @notice Thrown when the admin tries to reach the implementation through the proxy.
    error AdminCannotFallback();
    /// @notice Thrown when an address that must be non-zero (or a contract) is not.
    /// @param account The rejected address.
    error InvalidAddress(address account);
    /// @notice Thrown when the initialization delegatecall reverts without a reason.
    error InitializationFailed();

    /// @dev Admin calls run the proxy function; everyone else is delegated (transparent proxy).
    modifier ifAdmin() {
        if (msg.sender == _getAdmin()) {
            _;
        } else {
            _delegate(_getImplementation());
        }
    }

    /// @notice Deploy the proxy, set its admin and implementation, and run `initData` (if any)
    ///         against the implementation in the proxy's storage.
    /// @param impl Initial implementation (must be a contract).
    /// @param admin_ Proxy admin (non-zero).
    /// @param initData Initialization calldata delegatecalled into `impl`; empty to skip.
    constructor(address impl, address admin_, bytes memory initData) {
        require(impl.code.length != 0, InvalidAddress(impl));
        require(admin_ != address(0), InvalidAddress(admin_));
        _setImplementation(impl);
        _setAdmin(admin_);
        if (initData.length != 0) {
            // Delegatecall into the implementation that was just validated to be a contract;
            // this is the standard proxy initialization pattern.
            (bool ok, bytes memory ret) = impl.delegatecall(initData);
            if (!ok) {
                require(ret.length != 0, InitializationFailed());
                // Bubble the implementation's revert data. Memory-safe: reads only `ret`.
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }

    /// @notice The proxy admin. Admin only (other callers are delegated).
    /// @return account The admin address.
    function admin() external ifAdmin returns (address account) {
        account = _getAdmin();
    }

    /// @notice The current implementation. Admin only (other callers are delegated).
    /// @return impl The implementation address.
    function implementation() external ifAdmin returns (address impl) {
        impl = _getImplementation();
    }

    /// @notice Point the proxy at a new implementation. Admin only.
    /// @param newImpl The new implementation (must be a contract).
    function upgradeTo(address newImpl) external ifAdmin {
        require(newImpl.code.length != 0, InvalidAddress(newImpl));
        _setImplementation(newImpl);
    }

    /// @notice Hand the proxy to a new admin. Admin only.
    /// @param newAdmin The new admin (non-zero).
    function changeAdmin(address newAdmin) external ifAdmin {
        require(newAdmin != address(0), InvalidAddress(newAdmin));
        emit AdminChanged(_getAdmin(), newAdmin);
        _setAdmin(newAdmin);
    }

    /// @notice Delegate every non-admin call to the implementation. Non-payable: the config
    ///         takes no ETH, so none can be locked in the proxy.
    fallback() external {
        require(msg.sender != _getAdmin(), AdminCannotFallback());
        _delegate(_getImplementation());
    }

    /// @dev Read the admin.
    function _getAdmin() private view returns (address account) {
        account = _admin;
    }

    /// @dev Write the admin.
    function _setAdmin(address account) private {
        _admin = account;
    }

    /// @dev Read the implementation from the EIP-1967 slot.
    function _getImplementation() private view returns (address impl) {
        // Reads one fixed storage slot; no memory is touched.
        assembly ("memory-safe") {
            impl := sload(IMPLEMENTATION_SLOT)
        }
    }

    /// @dev Write the implementation to the EIP-1967 slot and emit {Upgraded}.
    function _setImplementation(address impl) private {
        // Writes one fixed storage slot; no memory is touched.
        assembly ("memory-safe") {
            sstore(IMPLEMENTATION_SLOT, impl)
        }
        emit Upgraded(impl);
    }

    /// @dev Delegatecall `impl` with the current calldata and return or revert with its result.
    function _delegate(address impl) private {
        // Standard delegating proxy: the call frame never returns to Solidity, so overwriting
        // scratch memory from offset 0 is safe.
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
