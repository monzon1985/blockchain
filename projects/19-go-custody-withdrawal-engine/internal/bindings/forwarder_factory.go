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

// ForwarderFactoryMetaData contains all meta data concerning the ForwarderFactory contract.
var ForwarderFactoryMetaData = bind.MetaData{
	ABI: "[{\"type\":\"constructor\",\"inputs\":[{\"name\":\"destination\",\"type\":\"address\",\"internalType\":\"addresspayable\"},{\"name\":\"initialOwner\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"DESTINATION\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"addresspayable\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"IMPLEMENTATION\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"acceptOwnership\",\"inputs\":[],\"outputs\":[],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"deploy\",\"inputs\":[{\"name\":\"salt\",\"type\":\"bytes32\",\"internalType\":\"bytes32\"}],\"outputs\":[{\"name\":\"forwarder\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"flushMany\",\"inputs\":[{\"name\":\"salts\",\"type\":\"bytes32[]\",\"internalType\":\"bytes32[]\"},{\"name\":\"token\",\"type\":\"address\",\"internalType\":\"contractIERC20\"}],\"outputs\":[{\"name\":\"total\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"flushNativeMany\",\"inputs\":[{\"name\":\"salts\",\"type\":\"bytes32[]\",\"internalType\":\"bytes32[]\"}],\"outputs\":[{\"name\":\"total\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"forwarderAddress\",\"inputs\":[{\"name\":\"salt\",\"type\":\"bytes32\",\"internalType\":\"bytes32\"}],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"isDeployed\",\"inputs\":[{\"name\":\"salt\",\"type\":\"bytes32\",\"internalType\":\"bytes32\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"owner\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"pendingOwner\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"renounceOwnership\",\"inputs\":[],\"outputs\":[],\"stateMutability\":\"pure\"},{\"type\":\"function\",\"name\":\"saltFor\",\"inputs\":[{\"name\":\"userId\",\"type\":\"string\",\"internalType\":\"string\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bytes32\",\"internalType\":\"bytes32\"}],\"stateMutability\":\"pure\"},{\"type\":\"function\",\"name\":\"transferOwnership\",\"inputs\":[{\"name\":\"newOwner\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[],\"stateMutability\":\"nonpayable\"},{\"type\":\"event\",\"name\":\"BatchFlushed\",\"inputs\":[{\"name\":\"token\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"forwarders\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"},{\"name\":\"total\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"ForwarderDeployed\",\"inputs\":[{\"name\":\"salt\",\"type\":\"bytes32\",\"indexed\":true,\"internalType\":\"bytes32\"},{\"name\":\"forwarder\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"OwnershipTransferStarted\",\"inputs\":[{\"name\":\"previousOwner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"newOwner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"OwnershipTransferred\",\"inputs\":[{\"name\":\"previousOwner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"newOwner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"}],\"anonymous\":false},{\"type\":\"error\",\"name\":\"EmptyBatch\",\"inputs\":[]},{\"type\":\"error\",\"name\":\"FailedDeployment\",\"inputs\":[]},{\"type\":\"error\",\"name\":\"InsufficientBalance\",\"inputs\":[{\"name\":\"balance\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"needed\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"OwnableInvalidOwner\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"OwnableUnauthorizedAccount\",\"inputs\":[{\"name\":\"account\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"OwnershipCannotBeRenounced\",\"inputs\":[]},{\"type\":\"error\",\"name\":\"ZeroDestination\",\"inputs\":[]}]",
	ID:  "ForwarderFactory",
	Bin: "0x60c060405234801561000f575f5ffd5b5060405161143438038061143483398101604081905261002e9161016b565b806001600160a01b03811661005c57604051631e4fbdf760e01b81525f600482015260240160405180910390fd5b610065816100df565b506001600160a01b03821661008d57604051637d0f1ea160e01b815260040160405180910390fd5b8160405161009a9061014a565b6001600160a01b039091168152602001604051809103905ff0801580156100c3573d5f5f3e3d5ffd5b506001600160a01b039081166080529190911660a052506101a3565b600180546001600160a01b03191690556100f8816100fb565b50565b5f80546001600160a01b038381166001600160a01b0319831681178455604051919092169283917f8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e09190a35050565b61068680610dae83390190565b6001600160a01b03811681146100f8575f5ffd5b5f5f6040838503121561017c575f5ffd5b825161018781610157565b602084015190925061019881610157565b809150509250929050565b60805160a051610bdc6101d25f395f6101c301525f81816101540152818161024c01526107c00152610bdc5ff3fe608060405234801561000f575f5ffd5b50600436106100da575f3560e01c806379ba5097116100885780638da5cb5b116100635780638da5cb5b146101e5578063c640458814610202578063e30c397814610215578063f2fde38b14610233575f5ffd5b806379ba5097146101a35780637a55034b146101ab5780638b78150e146101be575f5ffd5b80633a4741bd116100b85780633a4741bd1461014f578063715018a61461017657806374c0ff4f14610180575f5ffd5b80630d8e654d146100de5780632b85ba381461011b57806334d2e7ab1461012e575b5f5ffd5b6100f16100ec3660046109b6565b610246565b60405173ffffffffffffffffffffffffffffffffffffffff90911681526020015b60405180910390f35b6100f16101293660046109b6565b610277565b61014161013c366004610a15565b610289565b604051908152602001610112565b6100f17f000000000000000000000000000000000000000000000000000000000000000081565b61017e6103bc565b005b61019361018e3660046109b6565b6103ee565b6040519015158152602001610112565b61017e610417565b6101416101b9366004610a75565b610493565b6100f17f000000000000000000000000000000000000000000000000000000000000000081565b5f5473ffffffffffffffffffffffffffffffffffffffff166100f1565b610141610210366004610ac8565b6105f5565b60015473ffffffffffffffffffffffffffffffffffffffff166100f1565b61017e610241366004610b36565b610616565b5f6102717f0000000000000000000000000000000000000000000000000000000000000000836106c5565b92915050565b5f61028061073d565b61027182610791565b5f61029261073d565b815f8190036102cd576040517fc2e5347d00000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b5f5b81811015610379576102f88585838181106102ec576102ec610b51565b90506020020135610791565b73ffffffffffffffffffffffffffffffffffffffff16635d6fefc66040518163ffffffff1660e01b81526004016020604051808303815f875af1158015610341573d5f5f3e3d5ffd5b505050506040513d601f19601f820116820180604052508101906103659190610b7e565b61036f9084610b95565b92506001016102cf565b5060408051828152602081018490525f917f7195cf1427c5f9fcc84d0c55442f4b8f0322911aa46a61c4d1e6f25d655fdfea910160405180910390a25092915050565b6040517f2fab92ca00000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b5f6103f882610246565b73ffffffffffffffffffffffffffffffffffffffff163b151592915050565b600154339073ffffffffffffffffffffffffffffffffffffffff168114610487576040517f118cdaa700000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff821660048201526024015b60405180910390fd5b61049081610831565b50565b5f61049c61073d565b825f8190036104d7576040517fc2e5347d00000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b5f5b8181101561059b576104f68686838181106102ec576102ec610b51565b6040517f79c76e1a00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff868116600483015291909116906379c76e1a906024016020604051808303815f875af1158015610563573d5f5f3e3d5ffd5b505050506040513d601f19601f820116820180604052508101906105879190610b7e565b6105919084610b95565b92506001016104d9565b50604080518281526020810184905273ffffffffffffffffffffffffffffffffffffffff8516917f7195cf1427c5f9fcc84d0c55442f4b8f0322911aa46a61c4d1e6f25d655fdfea910160405180910390a2509392505050565b5f8282604051610606929190610bcd565b6040518091039020905092915050565b61061e61073d565b6001805473ffffffffffffffffffffffffffffffffffffffff83167fffffffffffffffffffffffff000000000000000000000000000000000000000090911681179091556106805f5473ffffffffffffffffffffffffffffffffffffffff1690565b73ffffffffffffffffffffffffffffffffffffffff167f38d16b8cac22d99fc7c124b9cd0de2d3fa1faef420bfe791d8c362d765e2270060405160405180910390a350565b6040513060388201526f5af43d82803e903d91602b57fd5bf3ff602482015260148101839052733d602d80600a3d3981f3363d3d373d3d3d363d738152605881018290526037600c820120607882015260556043909101205f9073ffffffffffffffffffffffffffffffffffffffff165b9392505050565b5f5473ffffffffffffffffffffffffffffffffffffffff16331461078f576040517f118cdaa700000000000000000000000000000000000000000000000000000000815233600482015260240161047e565b565b5f61079b82610246565b90508073ffffffffffffffffffffffffffffffffffffffff163b5f0361082c576107e57f000000000000000000000000000000000000000000000000000000000000000083610862565b90508073ffffffffffffffffffffffffffffffffffffffff16827fc75affcba1d4fa1f80e2799acc97a2d0a6c6b2f316f10d5f44d91fe6f46997b260405160405180910390a35b919050565b600180547fffffffffffffffffffffffff00000000000000000000000000000000000000001690556104908161086e565b5f61073683835f6108e2565b5f805473ffffffffffffffffffffffffffffffffffffffff8381167fffffffffffffffffffffffff0000000000000000000000000000000000000000831681178455604051919092169283917f8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e09190a35050565b5f81471015610926576040517fcf4791810000000000000000000000000000000000000000000000000000000081524760048201526024810183905260440161047e565b763d602d80600a3d3981f3363d3d373d3d3d363d730000008460601b60e81c175f526e5af43d82803e903d91602b57fd5bf38460781b17602052826037600984f5905073ffffffffffffffffffffffffffffffffffffffff8116610736576040517fb06ebf3d00000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b5f602082840312156109c6575f5ffd5b5035919050565b5f5f83601f8401126109dd575f5ffd5b50813567ffffffffffffffff8111156109f4575f5ffd5b6020830191508360208260051b8501011115610a0e575f5ffd5b9250929050565b5f5f60208385031215610a26575f5ffd5b823567ffffffffffffffff811115610a3c575f5ffd5b610a48858286016109cd565b90969095509350505050565b73ffffffffffffffffffffffffffffffffffffffff81168114610490575f5ffd5b5f5f5f60408486031215610a87575f5ffd5b833567ffffffffffffffff811115610a9d575f5ffd5b610aa9868287016109cd565b9094509250506020840135610abd81610a54565b809150509250925092565b5f5f60208385031215610ad9575f5ffd5b823567ffffffffffffffff811115610aef575f5ffd5b8301601f81018513610aff575f5ffd5b803567ffffffffffffffff811115610b15575f5ffd5b856020828401011115610b26575f5ffd5b6020919091019590945092505050565b5f60208284031215610b46575f5ffd5b813561073681610a54565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52603260045260245ffd5b5f60208284031215610b8e575f5ffd5b5051919050565b80820180821115610271577f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b818382375f91019081529190505660c060405234801561000f575f5ffd5b5060405161068638038061068683398101604081905261002e9161006a565b6001600160a01b03811661005557604051637d0f1ea160e01b815260040160405180910390fd5b336080526001600160a01b031660a052610097565b5f6020828403121561007a575f5ffd5b81516001600160a01b0381168114610090575f5ffd5b9392505050565b60805160a0516105b56100d15f395f818160cd01528181610196015261033801525f818160530152818160f301526101f801526105b55ff3fe608060405234801561000f575f5ffd5b506004361061004a575f3560e01c80632dd310001461004e5780635d6fefc61461009f57806379c76e1a146100b55780638b78150e146100c8575b5f5ffd5b6100757f000000000000000000000000000000000000000000000000000000000000000081565b60405173ffffffffffffffffffffffffffffffffffffffff90911681526020015b60405180910390f35b6100a76100ef565b604051908152602001610096565b6100a76100c3366004610564565b6101f4565b6100757f000000000000000000000000000000000000000000000000000000000000000081565b5f337f000000000000000000000000000000000000000000000000000000000000000073ffffffffffffffffffffffffffffffffffffffff81168214610186576040517f536dd9ef00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff9283166004820152911660248201526044015b60405180910390fd5b504791505080156101f1576101bb7f0000000000000000000000000000000000000000000000000000000000000000826103b3565b6040518181525f907f43a46ac5237b9605f9ffdc5ca9e3ada3bea496bd00815441705ff59446129fb19060200160405180910390a25b90565b5f337f000000000000000000000000000000000000000000000000000000000000000073ffffffffffffffffffffffffffffffffffffffff81168214610286576040517f536dd9ef00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff92831660048201529116602482015260440161017d565b50506040517f70a0823100000000000000000000000000000000000000000000000000000000815230600482015273ffffffffffffffffffffffffffffffffffffffff8316906370a0823190602401602060405180830381865afa1580156102f0573d5f5f3e3d5ffd5b505050506040513d601f19601f82011682018060405250810190610314919061059e565b905080156103ae5761035d73ffffffffffffffffffffffffffffffffffffffff83167f00000000000000000000000000000000000000000000000000000000000000008361045c565b8173ffffffffffffffffffffffffffffffffffffffff167f43a46ac5237b9605f9ffdc5ca9e3ada3bea496bd00815441705ff59446129fb1826040516103a591815260200190565b60405180910390a25b919050565b804710156103f6576040517fcf4791810000000000000000000000000000000000000000000000000000000081524760048201526024810182905260440161017d565b61040f828260405180602001604052805f8152506104bc565b15610418575050565b3d1561042a576104266104d1565b5050565b6040517fd6bda27500000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b61046983838360016104dc565b6104b7576040517f5274afe700000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff8416600482015260240161017d565b505050565b5f5f5f83516020850186885af1949350505050565b6040513d5f823e3d81fd5b6040517fa9059cbb000000000000000000000000000000000000000000000000000000005f81815273ffffffffffffffffffffffffffffffffffffffff8616600452602485905291602083604481808b5af1925060015f5114831661055857838315161561054c573d5f823e3d81fd5b5f873b113d1516831692505b60405250949350505050565b5f60208284031215610574575f5ffd5b813573ffffffffffffffffffffffffffffffffffffffff81168114610597575f5ffd5b9392505050565b5f602082840312156105ae575f5ffd5b505191905056",
}

// ForwarderFactory is an auto generated Go binding around an Ethereum contract.
type ForwarderFactory struct {
	abi abi.ABI
}

// GetABI returns the ABI associated with this contract binding.
func (c *ForwarderFactory) GetABI() abi.ABI {
	return c.abi
}

// NewForwarderFactory creates a new instance of ForwarderFactory.
func NewForwarderFactory() *ForwarderFactory {
	parsed, err := ForwarderFactoryMetaData.ParseABI()
	if err != nil {
		panic(errors.New("invalid ABI: " + err.Error()))
	}
	return &ForwarderFactory{abi: *parsed}
}

// Instance creates a wrapper for a deployed contract instance at the given address.
// Use this to create the instance object passed to abigen v2 library functions Call, Transact, etc.
func (c *ForwarderFactory) Instance(backend bind.ContractBackend, addr common.Address) *bind.BoundContract {
	return bind.NewBoundContract(addr, c.abi, backend, backend, backend)
}

// PackConstructor is the Go binding used to pack the parameters required for
// contract deployment.
//
// Solidity: constructor(address destination, address initialOwner) returns()
func (forwarderFactory *ForwarderFactory) PackConstructor(destination common.Address, initialOwner common.Address) []byte {
	enc, err := forwarderFactory.abi.Pack("", destination, initialOwner)
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
func (forwarderFactory *ForwarderFactory) PackDESTINATION() []byte {
	enc, err := forwarderFactory.abi.Pack("DESTINATION")
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
func (forwarderFactory *ForwarderFactory) TryPackDESTINATION() ([]byte, error) {
	return forwarderFactory.abi.Pack("DESTINATION")
}

// UnpackDESTINATION is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x8b78150e.
//
// Solidity: function DESTINATION() view returns(address)
func (forwarderFactory *ForwarderFactory) UnpackDESTINATION(data []byte) (common.Address, error) {
	out, err := forwarderFactory.abi.Unpack("DESTINATION", data)
	if err != nil {
		return *new(common.Address), err
	}
	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)
	return out0, nil
}

// PackIMPLEMENTATION is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x3a4741bd.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function IMPLEMENTATION() view returns(address)
func (forwarderFactory *ForwarderFactory) PackIMPLEMENTATION() []byte {
	enc, err := forwarderFactory.abi.Pack("IMPLEMENTATION")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackIMPLEMENTATION is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x3a4741bd.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function IMPLEMENTATION() view returns(address)
func (forwarderFactory *ForwarderFactory) TryPackIMPLEMENTATION() ([]byte, error) {
	return forwarderFactory.abi.Pack("IMPLEMENTATION")
}

// UnpackIMPLEMENTATION is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x3a4741bd.
//
// Solidity: function IMPLEMENTATION() view returns(address)
func (forwarderFactory *ForwarderFactory) UnpackIMPLEMENTATION(data []byte) (common.Address, error) {
	out, err := forwarderFactory.abi.Unpack("IMPLEMENTATION", data)
	if err != nil {
		return *new(common.Address), err
	}
	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)
	return out0, nil
}

// PackAcceptOwnership is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x79ba5097.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function acceptOwnership() returns()
func (forwarderFactory *ForwarderFactory) PackAcceptOwnership() []byte {
	enc, err := forwarderFactory.abi.Pack("acceptOwnership")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackAcceptOwnership is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x79ba5097.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function acceptOwnership() returns()
func (forwarderFactory *ForwarderFactory) TryPackAcceptOwnership() ([]byte, error) {
	return forwarderFactory.abi.Pack("acceptOwnership")
}

// PackDeploy is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x2b85ba38.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function deploy(bytes32 salt) returns(address forwarder)
func (forwarderFactory *ForwarderFactory) PackDeploy(salt [32]byte) []byte {
	enc, err := forwarderFactory.abi.Pack("deploy", salt)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackDeploy is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x2b85ba38.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function deploy(bytes32 salt) returns(address forwarder)
func (forwarderFactory *ForwarderFactory) TryPackDeploy(salt [32]byte) ([]byte, error) {
	return forwarderFactory.abi.Pack("deploy", salt)
}

// UnpackDeploy is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x2b85ba38.
//
// Solidity: function deploy(bytes32 salt) returns(address forwarder)
func (forwarderFactory *ForwarderFactory) UnpackDeploy(data []byte) (common.Address, error) {
	out, err := forwarderFactory.abi.Unpack("deploy", data)
	if err != nil {
		return *new(common.Address), err
	}
	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)
	return out0, nil
}

// PackFlushMany is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x7a55034b.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function flushMany(bytes32[] salts, address token) returns(uint256 total)
func (forwarderFactory *ForwarderFactory) PackFlushMany(salts [][32]byte, token common.Address) []byte {
	enc, err := forwarderFactory.abi.Pack("flushMany", salts, token)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackFlushMany is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x7a55034b.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function flushMany(bytes32[] salts, address token) returns(uint256 total)
func (forwarderFactory *ForwarderFactory) TryPackFlushMany(salts [][32]byte, token common.Address) ([]byte, error) {
	return forwarderFactory.abi.Pack("flushMany", salts, token)
}

// UnpackFlushMany is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x7a55034b.
//
// Solidity: function flushMany(bytes32[] salts, address token) returns(uint256 total)
func (forwarderFactory *ForwarderFactory) UnpackFlushMany(data []byte) (*big.Int, error) {
	out, err := forwarderFactory.abi.Unpack("flushMany", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackFlushNativeMany is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x34d2e7ab.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function flushNativeMany(bytes32[] salts) returns(uint256 total)
func (forwarderFactory *ForwarderFactory) PackFlushNativeMany(salts [][32]byte) []byte {
	enc, err := forwarderFactory.abi.Pack("flushNativeMany", salts)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackFlushNativeMany is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x34d2e7ab.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function flushNativeMany(bytes32[] salts) returns(uint256 total)
func (forwarderFactory *ForwarderFactory) TryPackFlushNativeMany(salts [][32]byte) ([]byte, error) {
	return forwarderFactory.abi.Pack("flushNativeMany", salts)
}

// UnpackFlushNativeMany is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x34d2e7ab.
//
// Solidity: function flushNativeMany(bytes32[] salts) returns(uint256 total)
func (forwarderFactory *ForwarderFactory) UnpackFlushNativeMany(data []byte) (*big.Int, error) {
	out, err := forwarderFactory.abi.Unpack("flushNativeMany", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackForwarderAddress is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x0d8e654d.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function forwarderAddress(bytes32 salt) view returns(address)
func (forwarderFactory *ForwarderFactory) PackForwarderAddress(salt [32]byte) []byte {
	enc, err := forwarderFactory.abi.Pack("forwarderAddress", salt)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackForwarderAddress is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x0d8e654d.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function forwarderAddress(bytes32 salt) view returns(address)
func (forwarderFactory *ForwarderFactory) TryPackForwarderAddress(salt [32]byte) ([]byte, error) {
	return forwarderFactory.abi.Pack("forwarderAddress", salt)
}

// UnpackForwarderAddress is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x0d8e654d.
//
// Solidity: function forwarderAddress(bytes32 salt) view returns(address)
func (forwarderFactory *ForwarderFactory) UnpackForwarderAddress(data []byte) (common.Address, error) {
	out, err := forwarderFactory.abi.Unpack("forwarderAddress", data)
	if err != nil {
		return *new(common.Address), err
	}
	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)
	return out0, nil
}

// PackIsDeployed is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x74c0ff4f.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function isDeployed(bytes32 salt) view returns(bool)
func (forwarderFactory *ForwarderFactory) PackIsDeployed(salt [32]byte) []byte {
	enc, err := forwarderFactory.abi.Pack("isDeployed", salt)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackIsDeployed is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x74c0ff4f.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function isDeployed(bytes32 salt) view returns(bool)
func (forwarderFactory *ForwarderFactory) TryPackIsDeployed(salt [32]byte) ([]byte, error) {
	return forwarderFactory.abi.Pack("isDeployed", salt)
}

// UnpackIsDeployed is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x74c0ff4f.
//
// Solidity: function isDeployed(bytes32 salt) view returns(bool)
func (forwarderFactory *ForwarderFactory) UnpackIsDeployed(data []byte) (bool, error) {
	out, err := forwarderFactory.abi.Unpack("isDeployed", data)
	if err != nil {
		return *new(bool), err
	}
	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)
	return out0, nil
}

// PackOwner is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x8da5cb5b.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function owner() view returns(address)
func (forwarderFactory *ForwarderFactory) PackOwner() []byte {
	enc, err := forwarderFactory.abi.Pack("owner")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackOwner is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x8da5cb5b.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function owner() view returns(address)
func (forwarderFactory *ForwarderFactory) TryPackOwner() ([]byte, error) {
	return forwarderFactory.abi.Pack("owner")
}

// UnpackOwner is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x8da5cb5b.
//
// Solidity: function owner() view returns(address)
func (forwarderFactory *ForwarderFactory) UnpackOwner(data []byte) (common.Address, error) {
	out, err := forwarderFactory.abi.Unpack("owner", data)
	if err != nil {
		return *new(common.Address), err
	}
	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)
	return out0, nil
}

// PackPendingOwner is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xe30c3978.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function pendingOwner() view returns(address)
func (forwarderFactory *ForwarderFactory) PackPendingOwner() []byte {
	enc, err := forwarderFactory.abi.Pack("pendingOwner")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackPendingOwner is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xe30c3978.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function pendingOwner() view returns(address)
func (forwarderFactory *ForwarderFactory) TryPackPendingOwner() ([]byte, error) {
	return forwarderFactory.abi.Pack("pendingOwner")
}

// UnpackPendingOwner is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xe30c3978.
//
// Solidity: function pendingOwner() view returns(address)
func (forwarderFactory *ForwarderFactory) UnpackPendingOwner(data []byte) (common.Address, error) {
	out, err := forwarderFactory.abi.Unpack("pendingOwner", data)
	if err != nil {
		return *new(common.Address), err
	}
	out0 := *abi.ConvertType(out[0], new(common.Address)).(*common.Address)
	return out0, nil
}

// PackRenounceOwnership is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x715018a6.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function renounceOwnership() pure returns()
func (forwarderFactory *ForwarderFactory) PackRenounceOwnership() []byte {
	enc, err := forwarderFactory.abi.Pack("renounceOwnership")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackRenounceOwnership is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x715018a6.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function renounceOwnership() pure returns()
func (forwarderFactory *ForwarderFactory) TryPackRenounceOwnership() ([]byte, error) {
	return forwarderFactory.abi.Pack("renounceOwnership")
}

// PackSaltFor is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xc6404588.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function saltFor(string userId) pure returns(bytes32)
func (forwarderFactory *ForwarderFactory) PackSaltFor(userId string) []byte {
	enc, err := forwarderFactory.abi.Pack("saltFor", userId)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackSaltFor is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xc6404588.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function saltFor(string userId) pure returns(bytes32)
func (forwarderFactory *ForwarderFactory) TryPackSaltFor(userId string) ([]byte, error) {
	return forwarderFactory.abi.Pack("saltFor", userId)
}

// UnpackSaltFor is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xc6404588.
//
// Solidity: function saltFor(string userId) pure returns(bytes32)
func (forwarderFactory *ForwarderFactory) UnpackSaltFor(data []byte) ([32]byte, error) {
	out, err := forwarderFactory.abi.Unpack("saltFor", data)
	if err != nil {
		return *new([32]byte), err
	}
	out0 := *abi.ConvertType(out[0], new([32]byte)).(*[32]byte)
	return out0, nil
}

// PackTransferOwnership is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xf2fde38b.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function transferOwnership(address newOwner) returns()
func (forwarderFactory *ForwarderFactory) PackTransferOwnership(newOwner common.Address) []byte {
	enc, err := forwarderFactory.abi.Pack("transferOwnership", newOwner)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackTransferOwnership is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xf2fde38b.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function transferOwnership(address newOwner) returns()
func (forwarderFactory *ForwarderFactory) TryPackTransferOwnership(newOwner common.Address) ([]byte, error) {
	return forwarderFactory.abi.Pack("transferOwnership", newOwner)
}

// ForwarderFactoryBatchFlushed represents a BatchFlushed event raised by the ForwarderFactory contract.
type ForwarderFactoryBatchFlushed struct {
	Token      common.Address
	Forwarders *big.Int
	Total      *big.Int
	Raw        *types.Log // Blockchain specific contextual infos
}

const ForwarderFactoryBatchFlushedEventName = "BatchFlushed"

// ContractEventName returns the user-defined event name.
func (ForwarderFactoryBatchFlushed) ContractEventName() string {
	return ForwarderFactoryBatchFlushedEventName
}

// UnpackBatchFlushedEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event BatchFlushed(address indexed token, uint256 forwarders, uint256 total)
func (forwarderFactory *ForwarderFactory) UnpackBatchFlushedEvent(log *types.Log) (*ForwarderFactoryBatchFlushed, error) {
	event := "BatchFlushed"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != forwarderFactory.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(ForwarderFactoryBatchFlushed)
	if len(log.Data) > 0 {
		if err := forwarderFactory.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range forwarderFactory.abi.Events[event].Inputs {
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

// ForwarderFactoryForwarderDeployed represents a ForwarderDeployed event raised by the ForwarderFactory contract.
type ForwarderFactoryForwarderDeployed struct {
	Salt      [32]byte
	Forwarder common.Address
	Raw       *types.Log // Blockchain specific contextual infos
}

const ForwarderFactoryForwarderDeployedEventName = "ForwarderDeployed"

// ContractEventName returns the user-defined event name.
func (ForwarderFactoryForwarderDeployed) ContractEventName() string {
	return ForwarderFactoryForwarderDeployedEventName
}

// UnpackForwarderDeployedEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event ForwarderDeployed(bytes32 indexed salt, address indexed forwarder)
func (forwarderFactory *ForwarderFactory) UnpackForwarderDeployedEvent(log *types.Log) (*ForwarderFactoryForwarderDeployed, error) {
	event := "ForwarderDeployed"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != forwarderFactory.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(ForwarderFactoryForwarderDeployed)
	if len(log.Data) > 0 {
		if err := forwarderFactory.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range forwarderFactory.abi.Events[event].Inputs {
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

// ForwarderFactoryOwnershipTransferStarted represents a OwnershipTransferStarted event raised by the ForwarderFactory contract.
type ForwarderFactoryOwnershipTransferStarted struct {
	PreviousOwner common.Address
	NewOwner      common.Address
	Raw           *types.Log // Blockchain specific contextual infos
}

const ForwarderFactoryOwnershipTransferStartedEventName = "OwnershipTransferStarted"

// ContractEventName returns the user-defined event name.
func (ForwarderFactoryOwnershipTransferStarted) ContractEventName() string {
	return ForwarderFactoryOwnershipTransferStartedEventName
}

// UnpackOwnershipTransferStartedEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)
func (forwarderFactory *ForwarderFactory) UnpackOwnershipTransferStartedEvent(log *types.Log) (*ForwarderFactoryOwnershipTransferStarted, error) {
	event := "OwnershipTransferStarted"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != forwarderFactory.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(ForwarderFactoryOwnershipTransferStarted)
	if len(log.Data) > 0 {
		if err := forwarderFactory.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range forwarderFactory.abi.Events[event].Inputs {
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

// ForwarderFactoryOwnershipTransferred represents a OwnershipTransferred event raised by the ForwarderFactory contract.
type ForwarderFactoryOwnershipTransferred struct {
	PreviousOwner common.Address
	NewOwner      common.Address
	Raw           *types.Log // Blockchain specific contextual infos
}

const ForwarderFactoryOwnershipTransferredEventName = "OwnershipTransferred"

// ContractEventName returns the user-defined event name.
func (ForwarderFactoryOwnershipTransferred) ContractEventName() string {
	return ForwarderFactoryOwnershipTransferredEventName
}

// UnpackOwnershipTransferredEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)
func (forwarderFactory *ForwarderFactory) UnpackOwnershipTransferredEvent(log *types.Log) (*ForwarderFactoryOwnershipTransferred, error) {
	event := "OwnershipTransferred"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != forwarderFactory.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(ForwarderFactoryOwnershipTransferred)
	if len(log.Data) > 0 {
		if err := forwarderFactory.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range forwarderFactory.abi.Events[event].Inputs {
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
func (forwarderFactory *ForwarderFactory) UnpackError(raw []byte) (any, error) {
	if bytes.Equal(raw[:4], forwarderFactory.abi.Errors["EmptyBatch"].ID.Bytes()[:4]) {
		return forwarderFactory.UnpackEmptyBatchError(raw[4:])
	}
	if bytes.Equal(raw[:4], forwarderFactory.abi.Errors["FailedDeployment"].ID.Bytes()[:4]) {
		return forwarderFactory.UnpackFailedDeploymentError(raw[4:])
	}
	if bytes.Equal(raw[:4], forwarderFactory.abi.Errors["InsufficientBalance"].ID.Bytes()[:4]) {
		return forwarderFactory.UnpackInsufficientBalanceError(raw[4:])
	}
	if bytes.Equal(raw[:4], forwarderFactory.abi.Errors["OwnableInvalidOwner"].ID.Bytes()[:4]) {
		return forwarderFactory.UnpackOwnableInvalidOwnerError(raw[4:])
	}
	if bytes.Equal(raw[:4], forwarderFactory.abi.Errors["OwnableUnauthorizedAccount"].ID.Bytes()[:4]) {
		return forwarderFactory.UnpackOwnableUnauthorizedAccountError(raw[4:])
	}
	if bytes.Equal(raw[:4], forwarderFactory.abi.Errors["OwnershipCannotBeRenounced"].ID.Bytes()[:4]) {
		return forwarderFactory.UnpackOwnershipCannotBeRenouncedError(raw[4:])
	}
	if bytes.Equal(raw[:4], forwarderFactory.abi.Errors["ZeroDestination"].ID.Bytes()[:4]) {
		return forwarderFactory.UnpackZeroDestinationError(raw[4:])
	}
	return nil, errors.New("Unknown error")
}

// ForwarderFactoryEmptyBatch represents a EmptyBatch error raised by the ForwarderFactory contract.
type ForwarderFactoryEmptyBatch struct {
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error EmptyBatch()
func ForwarderFactoryEmptyBatchErrorID() common.Hash {
	return common.HexToHash("0xc2e5347df6cf8d1bf68f8a9651642312bd381b900d857d97cd665976180d6ae0")
}

// UnpackEmptyBatchError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error EmptyBatch()
func (forwarderFactory *ForwarderFactory) UnpackEmptyBatchError(raw []byte) (*ForwarderFactoryEmptyBatch, error) {
	out := new(ForwarderFactoryEmptyBatch)
	if err := forwarderFactory.abi.UnpackIntoInterface(out, "EmptyBatch", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// ForwarderFactoryFailedDeployment represents a FailedDeployment error raised by the ForwarderFactory contract.
type ForwarderFactoryFailedDeployment struct {
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error FailedDeployment()
func ForwarderFactoryFailedDeploymentErrorID() common.Hash {
	return common.HexToHash("0xb06ebf3d5067824a3fe5d5ba19471e035a7de6c88dac362c77b162830a5b9093")
}

// UnpackFailedDeploymentError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error FailedDeployment()
func (forwarderFactory *ForwarderFactory) UnpackFailedDeploymentError(raw []byte) (*ForwarderFactoryFailedDeployment, error) {
	out := new(ForwarderFactoryFailedDeployment)
	if err := forwarderFactory.abi.UnpackIntoInterface(out, "FailedDeployment", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// ForwarderFactoryInsufficientBalance represents a InsufficientBalance error raised by the ForwarderFactory contract.
type ForwarderFactoryInsufficientBalance struct {
	Balance *big.Int
	Needed  *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error InsufficientBalance(uint256 balance, uint256 needed)
func ForwarderFactoryInsufficientBalanceErrorID() common.Hash {
	return common.HexToHash("0xcf4791818fba6e019216eb4864093b4947f674afada5d305e57d598b641dad1d")
}

// UnpackInsufficientBalanceError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error InsufficientBalance(uint256 balance, uint256 needed)
func (forwarderFactory *ForwarderFactory) UnpackInsufficientBalanceError(raw []byte) (*ForwarderFactoryInsufficientBalance, error) {
	out := new(ForwarderFactoryInsufficientBalance)
	if err := forwarderFactory.abi.UnpackIntoInterface(out, "InsufficientBalance", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// ForwarderFactoryOwnableInvalidOwner represents a OwnableInvalidOwner error raised by the ForwarderFactory contract.
type ForwarderFactoryOwnableInvalidOwner struct {
	Owner common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error OwnableInvalidOwner(address owner)
func ForwarderFactoryOwnableInvalidOwnerErrorID() common.Hash {
	return common.HexToHash("0x1e4fbdf7f3ef8bcaa855599e3abf48b232380f183f08f6f813d9ffa5bd585188")
}

// UnpackOwnableInvalidOwnerError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error OwnableInvalidOwner(address owner)
func (forwarderFactory *ForwarderFactory) UnpackOwnableInvalidOwnerError(raw []byte) (*ForwarderFactoryOwnableInvalidOwner, error) {
	out := new(ForwarderFactoryOwnableInvalidOwner)
	if err := forwarderFactory.abi.UnpackIntoInterface(out, "OwnableInvalidOwner", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// ForwarderFactoryOwnableUnauthorizedAccount represents a OwnableUnauthorizedAccount error raised by the ForwarderFactory contract.
type ForwarderFactoryOwnableUnauthorizedAccount struct {
	Account common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error OwnableUnauthorizedAccount(address account)
func ForwarderFactoryOwnableUnauthorizedAccountErrorID() common.Hash {
	return common.HexToHash("0x118cdaa7a341953d1887a2245fd6665d741c67c8c50581daa59e1d03373fa188")
}

// UnpackOwnableUnauthorizedAccountError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error OwnableUnauthorizedAccount(address account)
func (forwarderFactory *ForwarderFactory) UnpackOwnableUnauthorizedAccountError(raw []byte) (*ForwarderFactoryOwnableUnauthorizedAccount, error) {
	out := new(ForwarderFactoryOwnableUnauthorizedAccount)
	if err := forwarderFactory.abi.UnpackIntoInterface(out, "OwnableUnauthorizedAccount", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// ForwarderFactoryOwnershipCannotBeRenounced represents a OwnershipCannotBeRenounced error raised by the ForwarderFactory contract.
type ForwarderFactoryOwnershipCannotBeRenounced struct {
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error OwnershipCannotBeRenounced()
func ForwarderFactoryOwnershipCannotBeRenouncedErrorID() common.Hash {
	return common.HexToHash("0x2fab92ca4da7e80162387e93e02720bc4b98838c093385cac8fecf71a9b7de25")
}

// UnpackOwnershipCannotBeRenouncedError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error OwnershipCannotBeRenounced()
func (forwarderFactory *ForwarderFactory) UnpackOwnershipCannotBeRenouncedError(raw []byte) (*ForwarderFactoryOwnershipCannotBeRenounced, error) {
	out := new(ForwarderFactoryOwnershipCannotBeRenounced)
	if err := forwarderFactory.abi.UnpackIntoInterface(out, "OwnershipCannotBeRenounced", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// ForwarderFactoryZeroDestination represents a ZeroDestination error raised by the ForwarderFactory contract.
type ForwarderFactoryZeroDestination struct {
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ZeroDestination()
func ForwarderFactoryZeroDestinationErrorID() common.Hash {
	return common.HexToHash("0x7d0f1ea1e46ff932403b0b0c7d5e6ccb249a088247eba55c44e4adaf97d4f0b2")
}

// UnpackZeroDestinationError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ZeroDestination()
func (forwarderFactory *ForwarderFactory) UnpackZeroDestinationError(raw []byte) (*ForwarderFactoryZeroDestination, error) {
	out := new(ForwarderFactoryZeroDestination)
	if err := forwarderFactory.abi.UnpackIntoInterface(out, "ZeroDestination", raw); err != nil {
		return nil, err
	}
	return out, nil
}
