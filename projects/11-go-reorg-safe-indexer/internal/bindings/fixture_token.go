// Code generated via abigen V2 - DO NOT EDIT.
// This file is a generated binding and any manual changes will be lost.
// SPDX-License-Identifier: MIT

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

// FixtureTokenMetaData contains all meta data concerning the FixtureToken contract.
var FixtureTokenMetaData = bind.MetaData{
	ABI: "[{\"type\":\"constructor\",\"inputs\":[{\"name\":\"name_\",\"type\":\"string\",\"internalType\":\"string\"},{\"name\":\"symbol_\",\"type\":\"string\",\"internalType\":\"string\"},{\"name\":\"decimals_\",\"type\":\"uint8\",\"internalType\":\"uint8\"},{\"name\":\"owner_\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"acceptOwnership\",\"inputs\":[],\"outputs\":[],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"allowance\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"approve\",\"inputs\":[{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"balanceOf\",\"inputs\":[{\"name\":\"account\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"batchTransfer\",\"inputs\":[{\"name\":\"recipients\",\"type\":\"address[]\",\"internalType\":\"address[]\"},{\"name\":\"amounts\",\"type\":\"uint256[]\",\"internalType\":\"uint256[]\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"burn\",\"inputs\":[{\"name\":\"amount\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"decimals\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"uint8\",\"internalType\":\"uint8\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"mint\",\"inputs\":[{\"name\":\"to\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"amount\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"name\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"string\",\"internalType\":\"string\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"owner\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"pendingOwner\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"address\",\"internalType\":\"address\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"renounceOwnership\",\"inputs\":[],\"outputs\":[],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"symbol\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"string\",\"internalType\":\"string\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"totalSupply\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"transfer\",\"inputs\":[{\"name\":\"to\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"transferFrom\",\"inputs\":[{\"name\":\"from\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"to\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"transferOwnership\",\"inputs\":[{\"name\":\"newOwner\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[],\"stateMutability\":\"nonpayable\"},{\"type\":\"event\",\"name\":\"Approval\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"spender\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"OwnershipTransferStarted\",\"inputs\":[{\"name\":\"previousOwner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"newOwner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"OwnershipTransferred\",\"inputs\":[{\"name\":\"previousOwner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"newOwner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"Transfer\",\"inputs\":[{\"name\":\"from\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"to\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"error\",\"name\":\"ERC20InsufficientAllowance\",\"inputs\":[{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"allowance\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"needed\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"ERC20InsufficientBalance\",\"inputs\":[{\"name\":\"sender\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"balance\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"needed\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidApprover\",\"inputs\":[{\"name\":\"approver\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidReceiver\",\"inputs\":[{\"name\":\"receiver\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidSender\",\"inputs\":[{\"name\":\"sender\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidSpender\",\"inputs\":[{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"EmptyBatch\",\"inputs\":[]},{\"type\":\"error\",\"name\":\"LengthMismatch\",\"inputs\":[{\"name\":\"recipients\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"amounts\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"OwnableInvalidOwner\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"OwnableUnauthorizedAccount\",\"inputs\":[{\"name\":\"account\",\"type\":\"address\",\"internalType\":\"address\"}]}]",
	ID:  "FixtureToken",
	Bin: "0x60a060405234801561000f575f5ffd5b5060405161129e38038061129e83398101604081905261002e9161019d565b808484600361003d83826102c6565b50600461004a82826102c6565b5050506001600160a01b03811661007a57604051631e4fbdf760e01b81525f600482015260240160405180910390fd5b61008381610093565b505060ff16608052506103849050565b600680546001600160a01b03191690556100ac816100af565b50565b600580546001600160a01b038381166001600160a01b0319831681179093556040519116919082907f8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0905f90a35050565b634e487b7160e01b5f52604160045260245ffd5b5f82601f830112610123575f5ffd5b81516001600160401b0381111561013c5761013c610100565b604051601f8201601f19908116603f011681016001600160401b038111828210171561016a5761016a610100565b604052818152838201602001851015610181575f5ffd5b8160208501602083015e5f918101602001919091529392505050565b5f5f5f5f608085870312156101b0575f5ffd5b84516001600160401b038111156101c5575f5ffd5b6101d187828801610114565b602087015190955090506001600160401b038111156101ee575f5ffd5b6101fa87828801610114565b935050604085015160ff81168114610210575f5ffd5b60608601519092506001600160a01b038116811461022c575f5ffd5b939692955090935050565b600181811c9082168061024b57607f821691505b60208210810361026957634e487b7160e01b5f52602260045260245ffd5b50919050565b601f8211156102c157828211156102c157805f5260205f20601f840160051c602085101561029a57505f5b90810190601f840160051c035f5b818110156102bd575f838201556001016102a8565b5050505b505050565b81516001600160401b038111156102df576102df610100565b6102f3816102ed8454610237565b8461026f565b6020601f821160018114610325575f831561030e5750848201515b5f19600385901b1c1916600184901b17845561037d565b5f84815260208120601f198516915b828110156103545787850151825560209485019460019092019101610334565b508482101561037157868401515f19600387901b60f8161c191681555b505060018360011b0184555b5050505050565b608051610f0261039c5f395f6101860152610f025ff3fe608060405234801561000f575f5ffd5b5060043610610115575f3560e01c8063715018a6116100ad57806395d89b411161007d578063dd62ed3e11610063578063dd62ed3e1461028a578063e30c3978146102cf578063f2fde38b146102ed575f5ffd5b806395d89b411461026f578063a9059cbb14610277575f5ffd5b8063715018a61461020d57806379ba50971461021557806388d695b21461021d5780638da5cb5b14610230575f5ffd5b8063313ce567116100e8578063313ce5671461017f57806340c10f19146101b057806342966c68146101c557806370a08231146101d8575f5ffd5b806306fdde0314610119578063095ea7b31461013757806318160ddd1461015a57806323b872dd1461016c575b5f5ffd5b610121610300565b60405161012e9190610c53565b60405180910390f35b61014a610145366004610cce565b610390565b604051901515815260200161012e565b6002545b60405190815260200161012e565b61014a61017a366004610cf6565b6103a9565b60405160ff7f000000000000000000000000000000000000000000000000000000000000000016815260200161012e565b6101c36101be366004610cce565b6103cc565b005b6101c36101d3366004610d30565b6103e2565b61015e6101e6366004610d47565b73ffffffffffffffffffffffffffffffffffffffff165f9081526020819052604090205490565b6101c36103ef565b6101c3610402565b61014a61022b366004610daf565b61047b565b60055473ffffffffffffffffffffffffffffffffffffffff165b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200161012e565b610121610564565b61014a610285366004610cce565b610573565b61015e610298366004610e1b565b73ffffffffffffffffffffffffffffffffffffffff9182165f90815260016020908152604080832093909416825291909152205490565b60065473ffffffffffffffffffffffffffffffffffffffff1661024a565b6101c36102fb366004610d47565b610580565b60606003805461030f90610e4c565b80601f016020809104026020016040519081016040528092919081815260200182805461033b90610e4c565b80156103865780601f1061035d57610100808354040283529160200191610386565b820191905f5260205f20905b81548152906001019060200180831161036957829003601f168201915b5050505050905090565b5f3361039d818585610630565b60019150505b92915050565b5f336103b6858285610642565b6103c1858585610710565b506001949350505050565b6103d46107b9565b6103de828261080c565b5050565b6103ec3382610866565b50565b6103f76107b9565b6104005f6108c0565b565b600654339073ffffffffffffffffffffffffffffffffffffffff168114610472576040517f118cdaa700000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff821660048201526024015b60405180910390fd5b6103ec816108c0565b5f838082036104b6576040517fc2e5347d00000000000000000000000000000000000000000000000000000000815260040160405180910390fd5b80838181146104fa576040517fab8b67c600000000000000000000000000000000000000000000000000000000815260048101929092526024820152604401610469565b50505f5b818110156105575761054f3388888481811061051c5761051c610e9d565b90506020020160208101906105319190610d47565b87878581811061054357610543610e9d565b90506020020135610710565b6001016104fe565b5060019695505050505050565b60606004805461030f90610e4c565b5f3361039d818585610710565b6105886107b9565b6006805473ffffffffffffffffffffffffffffffffffffffff83167fffffffffffffffffffffffff000000000000000000000000000000000000000090911681179091556105eb60055473ffffffffffffffffffffffffffffffffffffffff1690565b73ffffffffffffffffffffffffffffffffffffffff167f38d16b8cac22d99fc7c124b9cd0de2d3fa1faef420bfe791d8c362d765e2270060405160405180910390a350565b61063d83838360016108f1565b505050565b73ffffffffffffffffffffffffffffffffffffffff8381165f908152600160209081526040808320938616835292905220547fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff81101561070a57818110156106fc576040517ffb8f41b200000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff841660048201526024810182905260448101839052606401610469565b61070a84848484035f6108f1565b50505050565b73ffffffffffffffffffffffffffffffffffffffff831661075f576040517f96c6fd1e0000000000000000000000000000000000000000000000000000000081525f6004820152602401610469565b73ffffffffffffffffffffffffffffffffffffffff82166107ae576040517fec442f050000000000000000000000000000000000000000000000000000000081525f6004820152602401610469565b61063d838383610a36565b60055473ffffffffffffffffffffffffffffffffffffffff163314610400576040517f118cdaa7000000000000000000000000000000000000000000000000000000008152336004820152602401610469565b73ffffffffffffffffffffffffffffffffffffffff821661085b576040517fec442f050000000000000000000000000000000000000000000000000000000081525f6004820152602401610469565b6103de5f8383610a36565b73ffffffffffffffffffffffffffffffffffffffff82166108b5576040517f96c6fd1e0000000000000000000000000000000000000000000000000000000081525f6004820152602401610469565b6103de825f83610a36565b600680547fffffffffffffffffffffffff00000000000000000000000000000000000000001690556103ec81610bdd565b73ffffffffffffffffffffffffffffffffffffffff8416610940576040517fe602df050000000000000000000000000000000000000000000000000000000081525f6004820152602401610469565b73ffffffffffffffffffffffffffffffffffffffff831661098f576040517f94280d620000000000000000000000000000000000000000000000000000000081525f6004820152602401610469565b73ffffffffffffffffffffffffffffffffffffffff8085165f908152600160209081526040808320938716835292905220829055801561070a578273ffffffffffffffffffffffffffffffffffffffff168473ffffffffffffffffffffffffffffffffffffffff167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b92584604051610a2891815260200190565b60405180910390a350505050565b73ffffffffffffffffffffffffffffffffffffffff8316610a6d578060025f828254610a629190610eca565b90915550610b1d9050565b73ffffffffffffffffffffffffffffffffffffffff83165f9081526020819052604090205481811015610af2576040517fe450d38c00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff851660048201526024810182905260448101839052606401610469565b73ffffffffffffffffffffffffffffffffffffffff84165f9081526020819052604090209082900390555b73ffffffffffffffffffffffffffffffffffffffff8216610b4657600280548290039055610b71565b73ffffffffffffffffffffffffffffffffffffffff82165f9081526020819052604090208054820190555b8173ffffffffffffffffffffffffffffffffffffffff168373ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef83604051610bd091815260200190565b60405180910390a3505050565b6005805473ffffffffffffffffffffffffffffffffffffffff8381167fffffffffffffffffffffffff0000000000000000000000000000000000000000831681179093556040519116919082907f8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0905f90a35050565b602081525f82518060208401528060208501604085015e5f6040828501015260407fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f83011684010191505092915050565b803573ffffffffffffffffffffffffffffffffffffffff81168114610cc9575f5ffd5b919050565b5f5f60408385031215610cdf575f5ffd5b610ce883610ca6565b946020939093013593505050565b5f5f5f60608486031215610d08575f5ffd5b610d1184610ca6565b9250610d1f60208501610ca6565b929592945050506040919091013590565b5f60208284031215610d40575f5ffd5b5035919050565b5f60208284031215610d57575f5ffd5b610d6082610ca6565b9392505050565b5f5f83601f840112610d77575f5ffd5b50813567ffffffffffffffff811115610d8e575f5ffd5b6020830191508360208260051b8501011115610da8575f5ffd5b9250929050565b5f5f5f5f60408587031215610dc2575f5ffd5b843567ffffffffffffffff811115610dd8575f5ffd5b610de487828801610d67565b909550935050602085013567ffffffffffffffff811115610e03575f5ffd5b610e0f87828801610d67565b95989497509550505050565b5f5f60408385031215610e2c575f5ffd5b610e3583610ca6565b9150610e4360208401610ca6565b90509250929050565b600181811c90821680610e6057607f821691505b602082108103610e97577f4e487b71000000000000000000000000000000000000000000000000000000005f52602260045260245ffd5b50919050565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52603260045260245ffd5b808201808211156103a3577f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd",
}

// FixtureToken is an auto generated Go binding around an Ethereum contract.
type FixtureToken struct {
	abi abi.ABI
}

// GetABI returns the ABI associated with this contract binding.
func (c *FixtureToken) GetABI() abi.ABI {
	return c.abi
}

// NewFixtureToken creates a new instance of FixtureToken.
func NewFixtureToken() *FixtureToken {
	parsed, err := FixtureTokenMetaData.ParseABI()
	if err != nil {
		panic(errors.New("invalid ABI: " + err.Error()))
	}
	return &FixtureToken{abi: *parsed}
}

// Instance creates a wrapper for a deployed contract instance at the given address.
// Use this to create the instance object passed to abigen v2 library functions Call, Transact, etc.
func (c *FixtureToken) Instance(backend bind.ContractBackend, addr common.Address) *bind.BoundContract {
	return bind.NewBoundContract(addr, c.abi, backend, backend, backend)
}

// PackConstructor is the Go binding used to pack the parameters required for
// contract deployment.
//
// Solidity: constructor(string name_, string symbol_, uint8 decimals_, address owner_) returns()
func (fixtureToken *FixtureToken) PackConstructor(name_ string, symbol_ string, decimals_ uint8, owner_ common.Address) []byte {
	enc, err := fixtureToken.abi.Pack("", name_, symbol_, decimals_, owner_)
	if err != nil {
		panic(err)
	}
	return enc
}

// PackAcceptOwnership is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x79ba5097.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function acceptOwnership() returns()
func (fixtureToken *FixtureToken) PackAcceptOwnership() []byte {
	enc, err := fixtureToken.abi.Pack("acceptOwnership")
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
func (fixtureToken *FixtureToken) TryPackAcceptOwnership() ([]byte, error) {
	return fixtureToken.abi.Pack("acceptOwnership")
}

// PackAllowance is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xdd62ed3e.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (fixtureToken *FixtureToken) PackAllowance(owner common.Address, spender common.Address) []byte {
	enc, err := fixtureToken.abi.Pack("allowance", owner, spender)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackAllowance is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xdd62ed3e.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (fixtureToken *FixtureToken) TryPackAllowance(owner common.Address, spender common.Address) ([]byte, error) {
	return fixtureToken.abi.Pack("allowance", owner, spender)
}

// UnpackAllowance is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xdd62ed3e.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (fixtureToken *FixtureToken) UnpackAllowance(data []byte) (*big.Int, error) {
	out, err := fixtureToken.abi.Unpack("allowance", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackApprove is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x095ea7b3.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (fixtureToken *FixtureToken) PackApprove(spender common.Address, value *big.Int) []byte {
	enc, err := fixtureToken.abi.Pack("approve", spender, value)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackApprove is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x095ea7b3.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (fixtureToken *FixtureToken) TryPackApprove(spender common.Address, value *big.Int) ([]byte, error) {
	return fixtureToken.abi.Pack("approve", spender, value)
}

// UnpackApprove is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x095ea7b3.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (fixtureToken *FixtureToken) UnpackApprove(data []byte) (bool, error) {
	out, err := fixtureToken.abi.Unpack("approve", data)
	if err != nil {
		return *new(bool), err
	}
	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)
	return out0, nil
}

// PackBalanceOf is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x70a08231.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (fixtureToken *FixtureToken) PackBalanceOf(account common.Address) []byte {
	enc, err := fixtureToken.abi.Pack("balanceOf", account)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackBalanceOf is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x70a08231.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (fixtureToken *FixtureToken) TryPackBalanceOf(account common.Address) ([]byte, error) {
	return fixtureToken.abi.Pack("balanceOf", account)
}

// UnpackBalanceOf is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x70a08231.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (fixtureToken *FixtureToken) UnpackBalanceOf(data []byte) (*big.Int, error) {
	out, err := fixtureToken.abi.Unpack("balanceOf", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackBatchTransfer is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x88d695b2.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function batchTransfer(address[] recipients, uint256[] amounts) returns(bool)
func (fixtureToken *FixtureToken) PackBatchTransfer(recipients []common.Address, amounts []*big.Int) []byte {
	enc, err := fixtureToken.abi.Pack("batchTransfer", recipients, amounts)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackBatchTransfer is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x88d695b2.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function batchTransfer(address[] recipients, uint256[] amounts) returns(bool)
func (fixtureToken *FixtureToken) TryPackBatchTransfer(recipients []common.Address, amounts []*big.Int) ([]byte, error) {
	return fixtureToken.abi.Pack("batchTransfer", recipients, amounts)
}

// UnpackBatchTransfer is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x88d695b2.
//
// Solidity: function batchTransfer(address[] recipients, uint256[] amounts) returns(bool)
func (fixtureToken *FixtureToken) UnpackBatchTransfer(data []byte) (bool, error) {
	out, err := fixtureToken.abi.Unpack("batchTransfer", data)
	if err != nil {
		return *new(bool), err
	}
	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)
	return out0, nil
}

// PackBurn is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x42966c68.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function burn(uint256 amount) returns()
func (fixtureToken *FixtureToken) PackBurn(amount *big.Int) []byte {
	enc, err := fixtureToken.abi.Pack("burn", amount)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackBurn is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x42966c68.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function burn(uint256 amount) returns()
func (fixtureToken *FixtureToken) TryPackBurn(amount *big.Int) ([]byte, error) {
	return fixtureToken.abi.Pack("burn", amount)
}

// PackDecimals is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x313ce567.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function decimals() view returns(uint8)
func (fixtureToken *FixtureToken) PackDecimals() []byte {
	enc, err := fixtureToken.abi.Pack("decimals")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackDecimals is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x313ce567.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function decimals() view returns(uint8)
func (fixtureToken *FixtureToken) TryPackDecimals() ([]byte, error) {
	return fixtureToken.abi.Pack("decimals")
}

// UnpackDecimals is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x313ce567.
//
// Solidity: function decimals() view returns(uint8)
func (fixtureToken *FixtureToken) UnpackDecimals(data []byte) (uint8, error) {
	out, err := fixtureToken.abi.Unpack("decimals", data)
	if err != nil {
		return *new(uint8), err
	}
	out0 := *abi.ConvertType(out[0], new(uint8)).(*uint8)
	return out0, nil
}

// PackMint is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x40c10f19.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function mint(address to, uint256 amount) returns()
func (fixtureToken *FixtureToken) PackMint(to common.Address, amount *big.Int) []byte {
	enc, err := fixtureToken.abi.Pack("mint", to, amount)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackMint is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x40c10f19.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function mint(address to, uint256 amount) returns()
func (fixtureToken *FixtureToken) TryPackMint(to common.Address, amount *big.Int) ([]byte, error) {
	return fixtureToken.abi.Pack("mint", to, amount)
}

// PackName is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x06fdde03.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function name() view returns(string)
func (fixtureToken *FixtureToken) PackName() []byte {
	enc, err := fixtureToken.abi.Pack("name")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackName is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x06fdde03.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function name() view returns(string)
func (fixtureToken *FixtureToken) TryPackName() ([]byte, error) {
	return fixtureToken.abi.Pack("name")
}

// UnpackName is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x06fdde03.
//
// Solidity: function name() view returns(string)
func (fixtureToken *FixtureToken) UnpackName(data []byte) (string, error) {
	out, err := fixtureToken.abi.Unpack("name", data)
	if err != nil {
		return *new(string), err
	}
	out0 := *abi.ConvertType(out[0], new(string)).(*string)
	return out0, nil
}

// PackOwner is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x8da5cb5b.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function owner() view returns(address)
func (fixtureToken *FixtureToken) PackOwner() []byte {
	enc, err := fixtureToken.abi.Pack("owner")
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
func (fixtureToken *FixtureToken) TryPackOwner() ([]byte, error) {
	return fixtureToken.abi.Pack("owner")
}

// UnpackOwner is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x8da5cb5b.
//
// Solidity: function owner() view returns(address)
func (fixtureToken *FixtureToken) UnpackOwner(data []byte) (common.Address, error) {
	out, err := fixtureToken.abi.Unpack("owner", data)
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
func (fixtureToken *FixtureToken) PackPendingOwner() []byte {
	enc, err := fixtureToken.abi.Pack("pendingOwner")
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
func (fixtureToken *FixtureToken) TryPackPendingOwner() ([]byte, error) {
	return fixtureToken.abi.Pack("pendingOwner")
}

// UnpackPendingOwner is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xe30c3978.
//
// Solidity: function pendingOwner() view returns(address)
func (fixtureToken *FixtureToken) UnpackPendingOwner(data []byte) (common.Address, error) {
	out, err := fixtureToken.abi.Unpack("pendingOwner", data)
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
// Solidity: function renounceOwnership() returns()
func (fixtureToken *FixtureToken) PackRenounceOwnership() []byte {
	enc, err := fixtureToken.abi.Pack("renounceOwnership")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackRenounceOwnership is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x715018a6.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function renounceOwnership() returns()
func (fixtureToken *FixtureToken) TryPackRenounceOwnership() ([]byte, error) {
	return fixtureToken.abi.Pack("renounceOwnership")
}

// PackSymbol is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x95d89b41.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function symbol() view returns(string)
func (fixtureToken *FixtureToken) PackSymbol() []byte {
	enc, err := fixtureToken.abi.Pack("symbol")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackSymbol is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x95d89b41.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function symbol() view returns(string)
func (fixtureToken *FixtureToken) TryPackSymbol() ([]byte, error) {
	return fixtureToken.abi.Pack("symbol")
}

// UnpackSymbol is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x95d89b41.
//
// Solidity: function symbol() view returns(string)
func (fixtureToken *FixtureToken) UnpackSymbol(data []byte) (string, error) {
	out, err := fixtureToken.abi.Unpack("symbol", data)
	if err != nil {
		return *new(string), err
	}
	out0 := *abi.ConvertType(out[0], new(string)).(*string)
	return out0, nil
}

// PackTotalSupply is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x18160ddd.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function totalSupply() view returns(uint256)
func (fixtureToken *FixtureToken) PackTotalSupply() []byte {
	enc, err := fixtureToken.abi.Pack("totalSupply")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackTotalSupply is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x18160ddd.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function totalSupply() view returns(uint256)
func (fixtureToken *FixtureToken) TryPackTotalSupply() ([]byte, error) {
	return fixtureToken.abi.Pack("totalSupply")
}

// UnpackTotalSupply is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x18160ddd.
//
// Solidity: function totalSupply() view returns(uint256)
func (fixtureToken *FixtureToken) UnpackTotalSupply(data []byte) (*big.Int, error) {
	out, err := fixtureToken.abi.Unpack("totalSupply", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackTransfer is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xa9059cbb.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (fixtureToken *FixtureToken) PackTransfer(to common.Address, value *big.Int) []byte {
	enc, err := fixtureToken.abi.Pack("transfer", to, value)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackTransfer is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xa9059cbb.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (fixtureToken *FixtureToken) TryPackTransfer(to common.Address, value *big.Int) ([]byte, error) {
	return fixtureToken.abi.Pack("transfer", to, value)
}

// UnpackTransfer is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xa9059cbb.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (fixtureToken *FixtureToken) UnpackTransfer(data []byte) (bool, error) {
	out, err := fixtureToken.abi.Unpack("transfer", data)
	if err != nil {
		return *new(bool), err
	}
	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)
	return out0, nil
}

// PackTransferFrom is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x23b872dd.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (fixtureToken *FixtureToken) PackTransferFrom(from common.Address, to common.Address, value *big.Int) []byte {
	enc, err := fixtureToken.abi.Pack("transferFrom", from, to, value)
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackTransferFrom is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x23b872dd.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (fixtureToken *FixtureToken) TryPackTransferFrom(from common.Address, to common.Address, value *big.Int) ([]byte, error) {
	return fixtureToken.abi.Pack("transferFrom", from, to, value)
}

// UnpackTransferFrom is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x23b872dd.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (fixtureToken *FixtureToken) UnpackTransferFrom(data []byte) (bool, error) {
	out, err := fixtureToken.abi.Unpack("transferFrom", data)
	if err != nil {
		return *new(bool), err
	}
	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)
	return out0, nil
}

// PackTransferOwnership is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xf2fde38b.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function transferOwnership(address newOwner) returns()
func (fixtureToken *FixtureToken) PackTransferOwnership(newOwner common.Address) []byte {
	enc, err := fixtureToken.abi.Pack("transferOwnership", newOwner)
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
func (fixtureToken *FixtureToken) TryPackTransferOwnership(newOwner common.Address) ([]byte, error) {
	return fixtureToken.abi.Pack("transferOwnership", newOwner)
}

// FixtureTokenApproval represents a Approval event raised by the FixtureToken contract.
type FixtureTokenApproval struct {
	Owner   common.Address
	Spender common.Address
	Value   *big.Int
	Raw     *types.Log // Blockchain specific contextual infos
}

const FixtureTokenApprovalEventName = "Approval"

// ContractEventName returns the user-defined event name.
func (FixtureTokenApproval) ContractEventName() string {
	return FixtureTokenApprovalEventName
}

// UnpackApprovalEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event Approval(address indexed owner, address indexed spender, uint256 value)
func (fixtureToken *FixtureToken) UnpackApprovalEvent(log *types.Log) (*FixtureTokenApproval, error) {
	event := "Approval"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != fixtureToken.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(FixtureTokenApproval)
	if len(log.Data) > 0 {
		if err := fixtureToken.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range fixtureToken.abi.Events[event].Inputs {
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

// FixtureTokenOwnershipTransferStarted represents a OwnershipTransferStarted event raised by the FixtureToken contract.
type FixtureTokenOwnershipTransferStarted struct {
	PreviousOwner common.Address
	NewOwner      common.Address
	Raw           *types.Log // Blockchain specific contextual infos
}

const FixtureTokenOwnershipTransferStartedEventName = "OwnershipTransferStarted"

// ContractEventName returns the user-defined event name.
func (FixtureTokenOwnershipTransferStarted) ContractEventName() string {
	return FixtureTokenOwnershipTransferStartedEventName
}

// UnpackOwnershipTransferStartedEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner)
func (fixtureToken *FixtureToken) UnpackOwnershipTransferStartedEvent(log *types.Log) (*FixtureTokenOwnershipTransferStarted, error) {
	event := "OwnershipTransferStarted"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != fixtureToken.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(FixtureTokenOwnershipTransferStarted)
	if len(log.Data) > 0 {
		if err := fixtureToken.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range fixtureToken.abi.Events[event].Inputs {
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

// FixtureTokenOwnershipTransferred represents a OwnershipTransferred event raised by the FixtureToken contract.
type FixtureTokenOwnershipTransferred struct {
	PreviousOwner common.Address
	NewOwner      common.Address
	Raw           *types.Log // Blockchain specific contextual infos
}

const FixtureTokenOwnershipTransferredEventName = "OwnershipTransferred"

// ContractEventName returns the user-defined event name.
func (FixtureTokenOwnershipTransferred) ContractEventName() string {
	return FixtureTokenOwnershipTransferredEventName
}

// UnpackOwnershipTransferredEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event OwnershipTransferred(address indexed previousOwner, address indexed newOwner)
func (fixtureToken *FixtureToken) UnpackOwnershipTransferredEvent(log *types.Log) (*FixtureTokenOwnershipTransferred, error) {
	event := "OwnershipTransferred"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != fixtureToken.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(FixtureTokenOwnershipTransferred)
	if len(log.Data) > 0 {
		if err := fixtureToken.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range fixtureToken.abi.Events[event].Inputs {
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

// FixtureTokenTransfer represents a Transfer event raised by the FixtureToken contract.
type FixtureTokenTransfer struct {
	From  common.Address
	To    common.Address
	Value *big.Int
	Raw   *types.Log // Blockchain specific contextual infos
}

const FixtureTokenTransferEventName = "Transfer"

// ContractEventName returns the user-defined event name.
func (FixtureTokenTransfer) ContractEventName() string {
	return FixtureTokenTransferEventName
}

// UnpackTransferEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event Transfer(address indexed from, address indexed to, uint256 value)
func (fixtureToken *FixtureToken) UnpackTransferEvent(log *types.Log) (*FixtureTokenTransfer, error) {
	event := "Transfer"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != fixtureToken.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(FixtureTokenTransfer)
	if len(log.Data) > 0 {
		if err := fixtureToken.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range fixtureToken.abi.Events[event].Inputs {
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
func (fixtureToken *FixtureToken) UnpackError(raw []byte) (any, error) {
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["ERC20InsufficientAllowance"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackERC20InsufficientAllowanceError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["ERC20InsufficientBalance"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackERC20InsufficientBalanceError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["ERC20InvalidApprover"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackERC20InvalidApproverError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["ERC20InvalidReceiver"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackERC20InvalidReceiverError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["ERC20InvalidSender"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackERC20InvalidSenderError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["ERC20InvalidSpender"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackERC20InvalidSpenderError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["EmptyBatch"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackEmptyBatchError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["LengthMismatch"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackLengthMismatchError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["OwnableInvalidOwner"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackOwnableInvalidOwnerError(raw[4:])
	}
	if bytes.Equal(raw[:4], fixtureToken.abi.Errors["OwnableUnauthorizedAccount"].ID.Bytes()[:4]) {
		return fixtureToken.UnpackOwnableUnauthorizedAccountError(raw[4:])
	}
	return nil, errors.New("Unknown error")
}

// FixtureTokenERC20InsufficientAllowance represents a ERC20InsufficientAllowance error raised by the FixtureToken contract.
type FixtureTokenERC20InsufficientAllowance struct {
	Spender   common.Address
	Allowance *big.Int
	Needed    *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)
func FixtureTokenERC20InsufficientAllowanceErrorID() common.Hash {
	return common.HexToHash("0xfb8f41b23e99d2101d86da76cdfa87dd51c82ed07d3cb62cbc473e469dbc75c3")
}

// UnpackERC20InsufficientAllowanceError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)
func (fixtureToken *FixtureToken) UnpackERC20InsufficientAllowanceError(raw []byte) (*FixtureTokenERC20InsufficientAllowance, error) {
	out := new(FixtureTokenERC20InsufficientAllowance)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "ERC20InsufficientAllowance", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureTokenERC20InsufficientBalance represents a ERC20InsufficientBalance error raised by the FixtureToken contract.
type FixtureTokenERC20InsufficientBalance struct {
	Sender  common.Address
	Balance *big.Int
	Needed  *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)
func FixtureTokenERC20InsufficientBalanceErrorID() common.Hash {
	return common.HexToHash("0xe450d38cd8d9f7d95077d567d60ed49c7254716e6ad08fc9872816c97e0ffec6")
}

// UnpackERC20InsufficientBalanceError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)
func (fixtureToken *FixtureToken) UnpackERC20InsufficientBalanceError(raw []byte) (*FixtureTokenERC20InsufficientBalance, error) {
	out := new(FixtureTokenERC20InsufficientBalance)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "ERC20InsufficientBalance", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureTokenERC20InvalidApprover represents a ERC20InvalidApprover error raised by the FixtureToken contract.
type FixtureTokenERC20InvalidApprover struct {
	Approver common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidApprover(address approver)
func FixtureTokenERC20InvalidApproverErrorID() common.Hash {
	return common.HexToHash("0xe602df05cc75712490294c6c104ab7c17f4030363910a7a2626411c6d3118847")
}

// UnpackERC20InvalidApproverError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidApprover(address approver)
func (fixtureToken *FixtureToken) UnpackERC20InvalidApproverError(raw []byte) (*FixtureTokenERC20InvalidApprover, error) {
	out := new(FixtureTokenERC20InvalidApprover)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "ERC20InvalidApprover", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureTokenERC20InvalidReceiver represents a ERC20InvalidReceiver error raised by the FixtureToken contract.
type FixtureTokenERC20InvalidReceiver struct {
	Receiver common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidReceiver(address receiver)
func FixtureTokenERC20InvalidReceiverErrorID() common.Hash {
	return common.HexToHash("0xec442f055133b72f3b2f9f0bb351c406b178527de2040a7d1feb4e058771f613")
}

// UnpackERC20InvalidReceiverError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidReceiver(address receiver)
func (fixtureToken *FixtureToken) UnpackERC20InvalidReceiverError(raw []byte) (*FixtureTokenERC20InvalidReceiver, error) {
	out := new(FixtureTokenERC20InvalidReceiver)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "ERC20InvalidReceiver", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureTokenERC20InvalidSender represents a ERC20InvalidSender error raised by the FixtureToken contract.
type FixtureTokenERC20InvalidSender struct {
	Sender common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidSender(address sender)
func FixtureTokenERC20InvalidSenderErrorID() common.Hash {
	return common.HexToHash("0x96c6fd1edd0cd6ef7ff0ecc0facdf53148dc0048b57fe58af65755250a7a96bd")
}

// UnpackERC20InvalidSenderError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidSender(address sender)
func (fixtureToken *FixtureToken) UnpackERC20InvalidSenderError(raw []byte) (*FixtureTokenERC20InvalidSender, error) {
	out := new(FixtureTokenERC20InvalidSender)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "ERC20InvalidSender", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureTokenERC20InvalidSpender represents a ERC20InvalidSpender error raised by the FixtureToken contract.
type FixtureTokenERC20InvalidSpender struct {
	Spender common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidSpender(address spender)
func FixtureTokenERC20InvalidSpenderErrorID() common.Hash {
	return common.HexToHash("0x94280d62c347d8d9f4d59a76ea321452406db88df38e0c9da304f58b57b373a2")
}

// UnpackERC20InvalidSpenderError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidSpender(address spender)
func (fixtureToken *FixtureToken) UnpackERC20InvalidSpenderError(raw []byte) (*FixtureTokenERC20InvalidSpender, error) {
	out := new(FixtureTokenERC20InvalidSpender)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "ERC20InvalidSpender", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureTokenEmptyBatch represents a EmptyBatch error raised by the FixtureToken contract.
type FixtureTokenEmptyBatch struct {
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error EmptyBatch()
func FixtureTokenEmptyBatchErrorID() common.Hash {
	return common.HexToHash("0xc2e5347df6cf8d1bf68f8a9651642312bd381b900d857d97cd665976180d6ae0")
}

// UnpackEmptyBatchError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error EmptyBatch()
func (fixtureToken *FixtureToken) UnpackEmptyBatchError(raw []byte) (*FixtureTokenEmptyBatch, error) {
	out := new(FixtureTokenEmptyBatch)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "EmptyBatch", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureTokenLengthMismatch represents a LengthMismatch error raised by the FixtureToken contract.
type FixtureTokenLengthMismatch struct {
	Recipients *big.Int
	Amounts    *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error LengthMismatch(uint256 recipients, uint256 amounts)
func FixtureTokenLengthMismatchErrorID() common.Hash {
	return common.HexToHash("0xab8b67c6893c59617ef3ba4b4b942e9791f2572db2fdb32028356532f3b7396a")
}

// UnpackLengthMismatchError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error LengthMismatch(uint256 recipients, uint256 amounts)
func (fixtureToken *FixtureToken) UnpackLengthMismatchError(raw []byte) (*FixtureTokenLengthMismatch, error) {
	out := new(FixtureTokenLengthMismatch)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "LengthMismatch", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureTokenOwnableInvalidOwner represents a OwnableInvalidOwner error raised by the FixtureToken contract.
type FixtureTokenOwnableInvalidOwner struct {
	Owner common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error OwnableInvalidOwner(address owner)
func FixtureTokenOwnableInvalidOwnerErrorID() common.Hash {
	return common.HexToHash("0x1e4fbdf7f3ef8bcaa855599e3abf48b232380f183f08f6f813d9ffa5bd585188")
}

// UnpackOwnableInvalidOwnerError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error OwnableInvalidOwner(address owner)
func (fixtureToken *FixtureToken) UnpackOwnableInvalidOwnerError(raw []byte) (*FixtureTokenOwnableInvalidOwner, error) {
	out := new(FixtureTokenOwnableInvalidOwner)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "OwnableInvalidOwner", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// FixtureTokenOwnableUnauthorizedAccount represents a OwnableUnauthorizedAccount error raised by the FixtureToken contract.
type FixtureTokenOwnableUnauthorizedAccount struct {
	Account common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error OwnableUnauthorizedAccount(address account)
func FixtureTokenOwnableUnauthorizedAccountErrorID() common.Hash {
	return common.HexToHash("0x118cdaa7a341953d1887a2245fd6665d741c67c8c50581daa59e1d03373fa188")
}

// UnpackOwnableUnauthorizedAccountError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error OwnableUnauthorizedAccount(address account)
func (fixtureToken *FixtureToken) UnpackOwnableUnauthorizedAccountError(raw []byte) (*FixtureTokenOwnableUnauthorizedAccount, error) {
	out := new(FixtureTokenOwnableUnauthorizedAccount)
	if err := fixtureToken.abi.UnpackIntoInterface(out, "OwnableUnauthorizedAccount", raw); err != nil {
		return nil, err
	}
	return out, nil
}
