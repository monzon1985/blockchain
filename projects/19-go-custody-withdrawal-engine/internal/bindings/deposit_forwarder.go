// SPDX-License-Identifier: MIT

// Code generated via abigen V2 - DO NOT EDIT.
// This file is a generated binding and any manual changes will be lost.

package bindings

import (
	"bytes"
	"errors"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind/v2"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

// Reference imports to suppress errors if they are not otherwise used.
var (
	_ = bytes.Equal
	_ = errors.New
	_ = big.NewInt
	_ = common.Big1
	_ = types.BloomLookup
	_ = abi.ConvertType
)

// DepositForwarderMetaData contains all meta data concerning the DepositForwarder contract.
var DepositForwarderMetaData = bind.MetaData{
	ABI: "[{\"type\":\"constructor\",\"inputs\":[{\"name\":\"destination\",\"type\":\"address\",\"internalType\":\"addresspayable\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"DESTINATION\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"addresspayable\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"FACTORY\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"flush\",\"inputs\":[{\"name\":\"token\",\"type\":\"address\",\"internalType\":\"contractIERC20\"}],\"outputs\":[{\"name\":\"amount\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"flushNative\",\"inputs\":[],\"outputs\":[{\"name\":\"amount\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"event\",\"name\":\"Flushed\",\"inputs\":[{\"name\":\"token\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"amount\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"error\",\"name\":\"FailedCall\",\"inputs\":[]},{\"type\":\"error\",\"name\":\"InsufficientBalance\",\"inputs\":[{\"name\":\"balance\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"needed\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"SafeERC20FailedOperation\",\"inputs\":[{\"name\":\"token\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"UnauthorizedCaller\",\"inputs\":[{\"name\":\"caller\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"factory\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ZeroDestination\",\"inputs\":[]}]",
	ID:  "DepositForwarder",
	Bin: "0x60c060405234801561000f575f5ffd5b5060405161068638038061068683398101604081905261002e9161006a565b6001600160a01b03811661005557604051637d0f1ea160e01b815260040160405180910390fd5b336080526001600160a01b031660a052610097565b5f6020828403121561007a575f5ffd5b81516001600160a01b0381168114610090575f5ffd5b9392505050565b60805160a0516105b56100d15f395f818160cd01528181610196015261033801525f818160530152818160f301526101f801526105b55ff3fe608060405234801561000f575f5ffd5b506004361061004a575f3560e01c80632dd310001461004e5780635d6fefc61461009f57806379c76e1a146100b55780638b78150e146100c8575b5f5ffd5b6100757f000000000000000000000000000000000000000000000000000000000000000081565b60405173ffffffffffffffffffffffffffffffffffffffff90911681526020015b60405180910390f35b6100a76100ef565b604051908152602001610096565b6100a76100c3366004610564565b6101f4565b6100757f000000000000000000000000000000000000000000000000000000000000000081565b5f337f000000000000000000000000000000000000000000000000000000000000000073ffffffffffffffffffffffffffffffffffffffff81168214610186576040517f536dd9ef00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff9283166004820152911660248201526044015b60405180910390fd5b504791505080156101f1576101bb7f0000000000000000000000000000000000000000000000000000000000000000826103b3565b6040518181525f907f43a46ac5237b9605f9ffdc5ca9e3ada3bea496bd00815441705ff59446129fb19060200160405180910390a25b90565b5f337f000000000000000000000000000000000000000000000000000000000000000073ffffffffffffffffffffffffffffffffffffffff81168214610286576040517f536dd9ef00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff92831660048201529116602482015260440161017d565b50506040517f70a0823100000000000000000000000000000000000000000000000000000000815230600482015273ffffffffffffffffffffffffffffffffffffffff8316906370a0823190602401602060405180830381865afa1580156102f0573d5f5f3e3d5ffd5b505050506040513d601f19601f82011682018060405250810190610314919061059e565b905080156103ae5761035d73ffffffffffffffffffffffffffffffffffffffff83167f00000000000000000000000000000000000000000000000000000000000000008361045c565b8173ffffffffffffffffffffffffffffffffffffffff167f43a46ac5237b9605f9ffdc5ca9e3ada3bea496bd00815441705ff59446129fb1826040516103a591815260200190565b60405180910390a25b919050565b804710156103f6576040517fcf4791810000000000000000000000000000000000000000000000000000000081524760048201526024810182905260440161017d565b61040f828260405180602001604052805f8152506104bc565b15610418575050565b3d1561042a576104266104d1565b5050565b6040517fd6bda27500000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b61046983838360016104dc565b6104b7576040517f5274afe700000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff8416600482015260240161017d565b505050565b5f5f5f83516020850186885af1949350505050565b6040513d5f823e3d81fd5b6040517fa9059cbb000000000000000000000000000000000000000000000000000000005f81815273ffffffffffffffffffffffffffffffffffffffff8616600452602485905291602083604481808b5af1925060015f5114831661055857838315161561054c573d5f823e3d81fd5b5f873b113d1516831692505b60405250949350505050565b5f60208284031215610574575f5ffd5b813573ffffffffffffffffffffffffffffffffffffffff81168114610597575f5ffd5b9392505050565b5f602082840312156105ae575f5ffd5b505191905056",
}

// DepositForwarder is an auto generated Go binding around an Ethereum contract.
type DepositForwarder struct {
	abi abi.ABI
}

// GetABI returns the ABI associated with this contract binding.
func (c *DepositForwarder) GetABI() abi.ABI {
	return c.abi
}

// NewDepositForwarder creates a new instance of DepositForwarder.
func NewDepositForwarder() *DepositForwarder {
	parsed, err := DepositForwarderMetaData.ParseABI()
	if err != nil {
		panic(errors.New("invalid ABI: " + err.Error()))
	}
	return &DepositForwarder{abi: *parsed}
}

// Instance creates a wrapper for a deployed contract instance at the given address.
// Use this to create the instance object passed to abigen v2 library functions Call, Transact, etc.
func (c *DepositForwarder) Instance(backend bind.ContractBackend, addr common.Address) *bind.BoundContract {
	return bind.NewBoundContract(addr, c.abi, backend, backend, backend)
}

// PackConstructor is the Go binding used to pack the parameters required for
// contract deployment.
//
// Solidity: constructor(address destination) returns()
func (depositForwarder *DepositForwarder) PackConstructor(destination common.Address) []byte {
	enc, err := depositForwarder.abi.Pack("", destination)
	if err != nil {
		panic(err)
	}
	return enc
}

// PackDESTINATION is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x8b78150e.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function DESTINATION() view returns(address)
func (depositForwarder *DepositForwarder) PackDESTINATION() []byte {
	enc, err := depositForwarder.abi.Pack("DESTINATION")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackDESTINATION is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x8b78150e.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function DESTINATION() view returns(address)
func (depositForwarder *DepositForwarder) TryPackDESTINATION() ([]byte, error) {
	return depositForwarder.abi.Pack("DESTINATION")
}

// UnpackDESTINATION is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x8b78150e.
//
// Solidity: function DESTINATION() view returns(address)
func (depositForwarder *DepositForwarder) UnpackDESTINATION(data []byte) (common.Address, error) {
	out, err := depositForwarder.abi.Unpack("DESTINATION", data)
	if err != nil {
		return *new(common.Address), err
	}
	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)
	return out0, nil
}

// PackFACTORY is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x2dd31000.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function FACTORY() view returns(address)
func (depositForwarder *DepositForwarder) PackFACTORY() []byte {
	enc, err := depositForwarder.abi.Pack("FACTORY")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackFACTORY is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x2dd31000.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function FACTORY() view returns(address)
func (depositForwarder *DepositForwarder) TryPackFACTORY() ([]byte, error) {
	return depositForwarder.abi.Pack("FACTORY")
}

// UnpackFACTORY is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x2dd31000.
//
// Solidity: function FACTORY() view returns(address)
func (depositForwarder *DepositForwarder) UnpackFACTORY(data []byte) (common.Address, error) {
	out, err := depositForwarder.abi.Unpack("FACTORY", data)
	if err != nil {
		return *new(common.Address), err
	}
	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)
	return out0, nil
}

// PackFlush is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x79c76e1a.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function flush(address token) returns(uint256 amount)
func (depositForwarder *DepositForwarder) PackFlush(token common.Address) []byte {
	enc, err := depositForwarder.abi.Pack("flush", token)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackFlush is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x79c76e1a.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function flush(address token) returns(uint256 amount)
func (depositForwarder *DepositForwarder) TryPackFlush(token common.Address) ([]byte, error) {
	return depositForwarder.abi.Pack("flush", token)
}

// UnpackFlush is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x79c76e1a.
//
// Solidity: function flush(address token) returns(uint256 amount)
func (depositForwarder *DepositForwarder) UnpackFlush(data []byte) (*big.Int, error) {
	out, err := depositForwarder.abi.Unpack("flush", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackFlushNative is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x5d6fefc6.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function flushNative() returns(uint256 amount)
func (depositForwarder *DepositForwarder) PackFlushNative() []byte {
	enc, err := depositForwarder.abi.Pack("flushNative")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackFlushNative is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x5d6fefc6.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function flushNative() returns(uint256 amount)
func (depositForwarder *DepositForwarder) TryPackFlushNative() ([]byte, error) {
	return depositForwarder.abi.Pack("flushNative")
}

// UnpackFlushNative is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x5d6fefc6.
//
// Solidity: function flushNative() returns(uint256 amount)
func (depositForwarder *DepositForwarder) UnpackFlushNative(data []byte) (*big.Int, error) {
	out, err := depositForwarder.abi.Unpack("flushNative", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// DepositForwarderFlushed represents a Flushed event raised by the DepositForwarder contract.
type DepositForwarderFlushed struct {
	Token  common.Address
	Amount *big.Int
	Raw    *types.Log // Blockchain specific contextual infos
}

const DepositForwarderFlushedEventName = "Flushed"

// ContractEventName returns the user-defined event name.
func (DepositForwarderFlushed) ContractEventName() string {
	return DepositForwarderFlushedEventName
}

// UnpackFlushedEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event Flushed(address indexed token, uint256 amount)
func (depositForwarder *DepositForwarder) UnpackFlushedEvent(log *types.Log) (*DepositForwarderFlushed, error) {
	event := "Flushed"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != depositForwarder.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(DepositForwarderFlushed)
	if len(log.Data) > 0 {
		if err := depositForwarder.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range depositForwarder.abi.Events[event].Inputs {
		if arg.Indexed {
			indexed = append(indexed, arg)
		}
	}
	if err := abi.ParseTopics(out, indexed, log.Topics[1:]); err != nil {
		return nil, err
	}
	out.Raw = log
	return out, nil
}

// UnpackError attempts to decode the provided error data using user-defined
// error definitions.
func (depositForwarder *DepositForwarder) UnpackError(raw []byte) (any, error) {
	if bytes.Equal(raw[:4], depositForwarder.abi.Errors["FailedCall"].ID.Bytes()[:4]) {
		return depositForwarder.UnpackFailedCallError(raw[4:])
	}
	if bytes.Equal(raw[:4], depositForwarder.abi.Errors["InsufficientBalance"].ID.Bytes()[:4]) {
		return depositForwarder.UnpackInsufficientBalanceError(raw[4:])
	}
	if bytes.Equal(raw[:4], depositForwarder.abi.Errors["SafeERC20FailedOperation"].ID.Bytes()[:4]) {
		return depositForwarder.UnpackSafeERC20FailedOperationError(raw[4:])
	}
	if bytes.Equal(raw[:4], depositForwarder.abi.Errors["UnauthorizedCaller"].ID.Bytes()[:4]) {
		return depositForwarder.UnpackUnauthorizedCallerError(raw[4:])
	}
	if bytes.Equal(raw[:4], depositForwarder.abi.Errors["ZeroDestination"].ID.Bytes()[:4]) {
		return depositForwarder.UnpackZeroDestinationError(raw[4:])
	}
	return nil, errors.New("Unknown error")
}

// DepositForwarderFailedCall represents a FailedCall error raised by the DepositForwarder contract.
type DepositForwarderFailedCall struct {
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error FailedCall()
func DepositForwarderFailedCallErrorID() common.Hash {
	return common.HexToHash("0xd6bda27508c0fb6d8a39b4b122878dab26f731a7d4e4abe711dd3731899052a4")
}

// UnpackFailedCallError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error FailedCall()
func (depositForwarder *DepositForwarder) UnpackFailedCallError(raw []byte) (*DepositForwarderFailedCall, error) {
	out := new(DepositForwarderFailedCall)
	if err := depositForwarder.abi.UnpackIntoInterface(out, "FailedCall", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// DepositForwarderInsufficientBalance represents a InsufficientBalance error raised by the DepositForwarder contract.
type DepositForwarderInsufficientBalance struct {
	Balance *big.Int
	Needed  *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error InsufficientBalance(uint256 balance, uint256 needed)
func DepositForwarderInsufficientBalanceErrorID() common.Hash {
	return common.HexToHash("0xcf4791818fba6e019216eb4864093b4947f674afada5d305e57d598b641dad1d")
}

// UnpackInsufficientBalanceError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error InsufficientBalance(uint256 balance, uint256 needed)
func (depositForwarder *DepositForwarder) UnpackInsufficientBalanceError(raw []byte) (*DepositForwarderInsufficientBalance, error) {
	out := new(DepositForwarderInsufficientBalance)
	if err := depositForwarder.abi.UnpackIntoInterface(out, "InsufficientBalance", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// DepositForwarderSafeERC20FailedOperation represents a SafeERC20FailedOperation error raised by the DepositForwarder contract.
type DepositForwarderSafeERC20FailedOperation struct {
	Token common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error SafeERC20FailedOperation(address token)
func DepositForwarderSafeERC20FailedOperationErrorID() common.Hash {
	return common.HexToHash("0x5274afe73c98b4749fc91ffae6b7b574e7842cb2144a159e9377a5f20b32edf9")
}

// UnpackSafeERC20FailedOperationError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error SafeERC20FailedOperation(address token)
func (depositForwarder *DepositForwarder) UnpackSafeERC20FailedOperationError(raw []byte) (*DepositForwarderSafeERC20FailedOperation, error) {
	out := new(DepositForwarderSafeERC20FailedOperation)
	if err := depositForwarder.abi.UnpackIntoInterface(out, "SafeERC20FailedOperation", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// DepositForwarderUnauthorizedCaller represents a UnauthorizedCaller error raised by the DepositForwarder contract.
type DepositForwarderUnauthorizedCaller struct {
	Caller  common.Address
	Factory common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error UnauthorizedCaller(address caller, address factory)
func DepositForwarderUnauthorizedCallerErrorID() common.Hash {
	return common.HexToHash("0x536dd9ef8353592a3222696b33828a6c11514bfd0c484dbdfd16491b4a82f8d8")
}

// UnpackUnauthorizedCallerError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error UnauthorizedCaller(address caller, address factory)
func (depositForwarder *DepositForwarder) UnpackUnauthorizedCallerError(raw []byte) (*DepositForwarderUnauthorizedCaller, error) {
	out := new(DepositForwarderUnauthorizedCaller)
	if err := depositForwarder.abi.UnpackIntoInterface(out, "UnauthorizedCaller", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// DepositForwarderZeroDestination represents a ZeroDestination error raised by the DepositForwarder contract.
type DepositForwarderZeroDestination struct {
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ZeroDestination()
func DepositForwarderZeroDestinationErrorID() common.Hash {
	return common.HexToHash("0x7d0f1ea1e46ff932403b0b0c7d5e6ccb249a088247eba55c44e4adaf97d4f0b2")
}

// UnpackZeroDestinationError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ZeroDestination()
func (depositForwarder *DepositForwarder) UnpackZeroDestinationError(raw []byte) (*DepositForwarderZeroDestination, error) {
	out := new(DepositForwarderZeroDestination)
	if err := depositForwarder.abi.UnpackIntoInterface(out, "ZeroDestination", raw); err != nil {
		return nil, err
	}
	return out, nil
}
