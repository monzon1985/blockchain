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

// TestTokenMetaData contains all meta data concerning the TestToken contract.
var TestTokenMetaData = bind.MetaData{
	ABI: "[{\"type\":\"constructor\",\"inputs\":[],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"allowance\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"approve\",\"inputs\":[{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"balanceOf\",\"inputs\":[{\"name\":\"account\",\"type\":\"address\",\"internalType\":\"address\"}],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"decimals\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"uint8\",\"internalType\":\"uint8\"}],\"stateMutability\":\"pure\"},{\"type\":\"function\",\"name\":\"mint\",\"inputs\":[{\"name\":\"to\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"amount\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"name\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"string\",\"internalType\":\"string\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"symbol\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"string\",\"internalType\":\"string\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"totalSupply\",\"inputs\":[],\"outputs\":[{\"name\":\"\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"stateMutability\":\"view\"},{\"type\":\"function\",\"name\":\"transfer\",\"inputs\":[{\"name\":\"to\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"function\",\"name\":\"transferFrom\",\"inputs\":[{\"name\":\"from\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"to\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"internalType\":\"uint256\"}],\"outputs\":[{\"name\":\"\",\"type\":\"bool\",\"internalType\":\"bool\"}],\"stateMutability\":\"nonpayable\"},{\"type\":\"event\",\"name\":\"Approval\",\"inputs\":[{\"name\":\"owner\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"spender\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"event\",\"name\":\"Transfer\",\"inputs\":[{\"name\":\"from\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"to\",\"type\":\"address\",\"indexed\":true,\"internalType\":\"address\"},{\"name\":\"value\",\"type\":\"uint256\",\"indexed\":false,\"internalType\":\"uint256\"}],\"anonymous\":false},{\"type\":\"error\",\"name\":\"ERC20InsufficientAllowance\",\"inputs\":[{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"allowance\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"needed\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"ERC20InsufficientBalance\",\"inputs\":[{\"name\":\"sender\",\"type\":\"address\",\"internalType\":\"address\"},{\"name\":\"balance\",\"type\":\"uint256\",\"internalType\":\"uint256\"},{\"name\":\"needed\",\"type\":\"uint256\",\"internalType\":\"uint256\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidApprover\",\"inputs\":[{\"name\":\"approver\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidReceiver\",\"inputs\":[{\"name\":\"receiver\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidSender\",\"inputs\":[{\"name\":\"sender\",\"type\":\"address\",\"internalType\":\"address\"}]},{\"type\":\"error\",\"name\":\"ERC20InvalidSpender\",\"inputs\":[{\"name\":\"spender\",\"type\":\"address\",\"internalType\":\"address\"}]}]",
	ID:  "TestToken",
	Bin: "0x608060405234801561000f575f5ffd5b506040518060400160405280601081526020016f10dd5cdd1bd91e4815195cdd081554d160821b815250604051806040016040528060048152602001631d1554d160e21b8152508160039081610065919061011d565b506004610072828261011d565b5050506101db565b634e487b7160e01b5f52604160045260245ffd5b600181811c908216806100a257607f821691505b6020821081036100c057634e487b7160e01b5f52602260045260245ffd5b50919050565b601f821115610118578282111561011857805f5260205f20601f840160051c60208510156100f157505f5b90810190601f840160051c035f5b81811015610114575f838201556001016100ff565b5050505b505050565b81516001600160401b038111156101365761013661007a565b61014a81610144845461008e565b846100c6565b6020601f82116001811461017c575f83156101655750848201515b5f19600385901b1c1916600184901b1784556101d4565b5f84815260208120601f198516915b828110156101ab578785015182556020948501946001909201910161018b565b50848210156101c857868401515f19600387901b60f8161c191681555b505060018360011b0184555b5050505050565b61095d806101e85f395ff3fe608060405234801561000f575f5ffd5b50600436106100b9575f3560e01c806340c10f191161007257806395d89b411161005857806395d89b411461017c578063a9059cbb14610184578063dd62ed3e14610197575f5ffd5b806340c10f191461013257806370a0823114610147575f5ffd5b806318160ddd116100a257806318160ddd146100fe57806323b872dd14610110578063313ce56714610123575f5ffd5b806306fdde03146100bd578063095ea7b3146100db575b5f5ffd5b6100c56101dc565b6040516100d291906107a6565b60405180910390f35b6100ee6100e9366004610821565b61026c565b60405190151581526020016100d2565b6002545b6040519081526020016100d2565b6100ee61011e366004610849565b610285565b604051600681526020016100d2565b610145610140366004610821565b6102a8565b005b610102610155366004610883565b73ffffffffffffffffffffffffffffffffffffffff165f9081526020819052604090205490565b6100c56102b6565b6100ee610192366004610821565b6102c5565b6101026101a53660046108a3565b73ffffffffffffffffffffffffffffffffffffffff9182165f90815260016020908152604080832093909416825291909152205490565b6060600380546101eb906108d4565b80601f0160208091040260200160405190810160405280929190818152602001828054610217906108d4565b80156102625780601f1061023957610100808354040283529160200191610262565b820191905f5260205f20905b81548152906001019060200180831161024557829003601f168201915b5050505050905090565b5f336102798185856102d2565b60019150505b92915050565b5f336102928582856102e4565b61029d8585856103b7565b506001949350505050565b6102b28282610460565b5050565b6060600480546101eb906108d4565b5f336102798185856103b7565b6102df83838360016104ba565b505050565b73ffffffffffffffffffffffffffffffffffffffff8381165f908152600160209081526040808320938616835292905220547fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff8110156103b157818110156103a3576040517ffb8f41b200000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff8416600482015260248101829052604481018390526064015b60405180910390fd5b6103b184848484035f6104ba565b50505050565b73ffffffffffffffffffffffffffffffffffffffff8316610406576040517f96c6fd1e0000000000000000000000000000000000000000000000000000000081525f600482015260240161039a565b73ffffffffffffffffffffffffffffffffffffffff8216610455576040517fec442f050000000000000000000000000000000000000000000000000000000081525f600482015260240161039a565b6102df8383836105ff565b73ffffffffffffffffffffffffffffffffffffffff82166104af576040517fec442f050000000000000000000000000000000000000000000000000000000081525f600482015260240161039a565b6102b25f83836105ff565b73ffffffffffffffffffffffffffffffffffffffff8416610509576040517fe602df050000000000000000000000000000000000000000000000000000000081525f600482015260240161039a565b73ffffffffffffffffffffffffffffffffffffffff8316610558576040517f94280d620000000000000000000000000000000000000000000000000000000081525f600482015260240161039a565b73ffffffffffffffffffffffffffffffffffffffff8085165f90815260016020908152604080832093871683529290522082905580156103b1578273ffffffffffffffffffffffffffffffffffffffff168473ffffffffffffffffffffffffffffffffffffffff167f8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925846040516105f191815260200190565b60405180910390a350505050565b73ffffffffffffffffffffffffffffffffffffffff8316610636578060025f82825461062b9190610925565b909155506106e69050565b73ffffffffffffffffffffffffffffffffffffffff83165f90815260208190526040902054818110156106bb576040517fe450d38c00000000000000000000000000000000000000000000000000000000815273ffffffffffffffffffffffffffffffffffffffff85166004820152602481018290526044810183905260640161039a565b73ffffffffffffffffffffffffffffffffffffffff84165f9081526020819052604090209082900390555b73ffffffffffffffffffffffffffffffffffffffff821661070f5760028054829003905561073a565b73ffffffffffffffffffffffffffffffffffffffff82165f9081526020819052604090208054820190555b8173ffffffffffffffffffffffffffffffffffffffff168373ffffffffffffffffffffffffffffffffffffffff167fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef8360405161079991815260200190565b60405180910390a3505050565b602081525f82518060208401528060208501604085015e5f6040828501015260407fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0601f83011684010191505092915050565b803573ffffffffffffffffffffffffffffffffffffffff8116811461081c575f5ffd5b919050565b5f5f60408385031215610832575f5ffd5b61083b836107f9565b946020939093013593505050565b5f5f5f6060848603121561085b575f5ffd5b610864846107f9565b9250610872602085016107f9565b929592945050506040919091013590565b5f60208284031215610893575f5ffd5b61089c826107f9565b9392505050565b5f5f604083850312156108b4575f5ffd5b6108bd836107f9565b91506108cb602084016107f9565b90509250929050565b600181811c908216806108e857607f821691505b60208210810361091f577f4e487b71000000000000000000000000000000000000000000000000000000005f52602260045260245ffd5b50919050565b8082018082111561027f577f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd",
}

// TestToken is an auto generated Go binding around an Ethereum contract.
type TestToken struct {
	abi abi.ABI
}

// GetABI returns the ABI associated with this contract binding.
func (c *TestToken) GetABI() abi.ABI {
	return c.abi
}

// NewTestToken creates a new instance of TestToken.
func NewTestToken() *TestToken {
	parsed, err := TestTokenMetaData.ParseABI()
	if err != nil {
		panic(errors.New("invalid ABI: " + err.Error()))
	}
	return &TestToken{abi: *parsed}
}

// Instance creates a wrapper for a deployed contract instance at the given address.
// Use this to create the instance object passed to abigen v2 library functions Call, Transact, etc.
func (c *TestToken) Instance(backend bind.ContractBackend, addr common.Address) *bind.BoundContract {
	return bind.NewBoundContract(addr, c.abi, backend, backend, backend)
}

// PackAllowance is the Go binding used to pack the parameters required for calling
// the contract method with ID 0xdd62ed3e.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (testToken *TestToken) PackAllowance(owner common.Address, spender common.Address) []byte {
	enc, err := testToken.abi.Pack("allowance", owner, spender)
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
func (testToken *TestToken) TryPackAllowance(owner common.Address, spender common.Address) ([]byte, error) {
	return testToken.abi.Pack("allowance", owner, spender)
}

// UnpackAllowance is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xdd62ed3e.
//
// Solidity: function allowance(address owner, address spender) view returns(uint256)
func (testToken *TestToken) UnpackAllowance(data []byte) (*big.Int, error) {
	out, err := testToken.abi.Unpack("allowance", data)
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
func (testToken *TestToken) PackApprove(spender common.Address, value *big.Int) []byte {
	enc, err := testToken.abi.Pack("approve", spender, value)
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
func (testToken *TestToken) TryPackApprove(spender common.Address, value *big.Int) ([]byte, error) {
	return testToken.abi.Pack("approve", spender, value)
}

// UnpackApprove is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x095ea7b3.
//
// Solidity: function approve(address spender, uint256 value) returns(bool)
func (testToken *TestToken) UnpackApprove(data []byte) (bool, error) {
	out, err := testToken.abi.Unpack("approve", data)
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
func (testToken *TestToken) PackBalanceOf(account common.Address) []byte {
	enc, err := testToken.abi.Pack("balanceOf", account)
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
func (testToken *TestToken) TryPackBalanceOf(account common.Address) ([]byte, error) {
	return testToken.abi.Pack("balanceOf", account)
}

// UnpackBalanceOf is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x70a08231.
//
// Solidity: function balanceOf(address account) view returns(uint256)
func (testToken *TestToken) UnpackBalanceOf(data []byte) (*big.Int, error) {
	out, err := testToken.abi.Unpack("balanceOf", data)
	if err != nil {
		return new(big.Int), err
	}
	out0 := abi.ConvertType(out[0], new(big.Int)).(*big.Int)
	return out0, nil
}

// PackDecimals is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x313ce567.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function decimals() pure returns(uint8)
func (testToken *TestToken) PackDecimals() []byte {
	enc, err := testToken.abi.Pack("decimals")
	if err != nil {
		panic(err)
	}
	return enc
}

// TryPackDecimals is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x313ce567.  This method will return an error
// if any inputs are invalid/nil.
//
// Solidity: function decimals() pure returns(uint8)
func (testToken *TestToken) TryPackDecimals() ([]byte, error) {
	return testToken.abi.Pack("decimals")
}

// UnpackDecimals is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x313ce567.
//
// Solidity: function decimals() pure returns(uint8)
func (testToken *TestToken) UnpackDecimals(data []byte) (uint8, error) {
	out, err := testToken.abi.Unpack("decimals", data)
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
func (testToken *TestToken) PackMint(to common.Address, amount *big.Int) []byte {
	enc, err := testToken.abi.Pack("mint", to, amount)
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
func (testToken *TestToken) TryPackMint(to common.Address, amount *big.Int) ([]byte, error) {
	return testToken.abi.Pack("mint", to, amount)
}

// PackName is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x06fdde03.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function name() view returns(string)
func (testToken *TestToken) PackName() []byte {
	enc, err := testToken.abi.Pack("name")
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
func (testToken *TestToken) TryPackName() ([]byte, error) {
	return testToken.abi.Pack("name")
}

// UnpackName is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x06fdde03.
//
// Solidity: function name() view returns(string)
func (testToken *TestToken) UnpackName(data []byte) (string, error) {
	out, err := testToken.abi.Unpack("name", data)
	if err != nil {
		return *new(string), err
	}
	out0 := *abi.ConvertType(out[0], new(string)).(*string)
	return out0, nil
}

// PackSymbol is the Go binding used to pack the parameters required for calling
// the contract method with ID 0x95d89b41.  This method will panic if any
// invalid/nil inputs are passed.
//
// Solidity: function symbol() view returns(string)
func (testToken *TestToken) PackSymbol() []byte {
	enc, err := testToken.abi.Pack("symbol")
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
func (testToken *TestToken) TryPackSymbol() ([]byte, error) {
	return testToken.abi.Pack("symbol")
}

// UnpackSymbol is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x95d89b41.
//
// Solidity: function symbol() view returns(string)
func (testToken *TestToken) UnpackSymbol(data []byte) (string, error) {
	out, err := testToken.abi.Unpack("symbol", data)
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
func (testToken *TestToken) PackTotalSupply() []byte {
	enc, err := testToken.abi.Pack("totalSupply")
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
func (testToken *TestToken) TryPackTotalSupply() ([]byte, error) {
	return testToken.abi.Pack("totalSupply")
}

// UnpackTotalSupply is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x18160ddd.
//
// Solidity: function totalSupply() view returns(uint256)
func (testToken *TestToken) UnpackTotalSupply(data []byte) (*big.Int, error) {
	out, err := testToken.abi.Unpack("totalSupply", data)
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
func (testToken *TestToken) PackTransfer(to common.Address, value *big.Int) []byte {
	enc, err := testToken.abi.Pack("transfer", to, value)
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
func (testToken *TestToken) TryPackTransfer(to common.Address, value *big.Int) ([]byte, error) {
	return testToken.abi.Pack("transfer", to, value)
}

// UnpackTransfer is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0xa9059cbb.
//
// Solidity: function transfer(address to, uint256 value) returns(bool)
func (testToken *TestToken) UnpackTransfer(data []byte) (bool, error) {
	out, err := testToken.abi.Unpack("transfer", data)
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
func (testToken *TestToken) PackTransferFrom(from common.Address, to common.Address, value *big.Int) []byte {
	enc, err := testToken.abi.Pack("transferFrom", from, to, value)
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
func (testToken *TestToken) TryPackTransferFrom(from common.Address, to common.Address, value *big.Int) ([]byte, error) {
	return testToken.abi.Pack("transferFrom", from, to, value)
}

// UnpackTransferFrom is the Go binding that unpacks the parameters returned
// from invoking the contract method with ID 0x23b872dd.
//
// Solidity: function transferFrom(address from, address to, uint256 value) returns(bool)
func (testToken *TestToken) UnpackTransferFrom(data []byte) (bool, error) {
	out, err := testToken.abi.Unpack("transferFrom", data)
	if err != nil {
		return *new(bool), err
	}
	out0 := *abi.ConvertType(out[0], new(bool)).(*bool)
	return out0, nil
}

// TestTokenApproval represents a Approval event raised by the TestToken contract.
type TestTokenApproval struct {
	Owner   common.Address
	Spender common.Address
	Value   *big.Int
	Raw     *types.Log // Blockchain specific contextual infos
}

const TestTokenApprovalEventName = "Approval"

// ContractEventName returns the user-defined event name.
func (TestTokenApproval) ContractEventName() string {
	return TestTokenApprovalEventName
}

// UnpackApprovalEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event Approval(address indexed owner, address indexed spender, uint256 value)
func (testToken *TestToken) UnpackApprovalEvent(log *types.Log) (*TestTokenApproval, error) {
	event := "Approval"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != testToken.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(TestTokenApproval)
	if len(log.Data) > 0 {
		if err := testToken.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range testToken.abi.Events[event].Inputs {
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

// TestTokenTransfer represents a Transfer event raised by the TestToken contract.
type TestTokenTransfer struct {
	From  common.Address
	To    common.Address
	Value *big.Int
	Raw   *types.Log // Blockchain specific contextual infos
}

const TestTokenTransferEventName = "Transfer"

// ContractEventName returns the user-defined event name.
func (TestTokenTransfer) ContractEventName() string {
	return TestTokenTransferEventName
}

// UnpackTransferEvent is the Go binding that unpacks the event data emitted
// by contract.
//
// Solidity: event Transfer(address indexed from, address indexed to, uint256 value)
func (testToken *TestToken) UnpackTransferEvent(log *types.Log) (*TestTokenTransfer, error) {
	event := "Transfer"
	if len(log.Topics) == 0 {
		return nil, bind.ErrNoEventSignature
	}
	if log.Topics[0] != testToken.abi.Events[event].ID {
		return nil, bind.ErrEventSignatureMismatch
	}
	out := new(TestTokenTransfer)
	if len(log.Data) > 0 {
		if err := testToken.abi.UnpackIntoInterface(out, event, log.Data); err != nil {
			return nil, err
		}
	}
	var indexed abi.Arguments
	for _, arg := range testToken.abi.Events[event].Inputs {
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
func (testToken *TestToken) UnpackError(raw []byte) (any, error) {
	if bytes.Equal(raw[:4], testToken.abi.Errors["ERC20InsufficientAllowance"].ID.Bytes()[:4]) {
		return testToken.UnpackERC20InsufficientAllowanceError(raw[4:])
	}
	if bytes.Equal(raw[:4], testToken.abi.Errors["ERC20InsufficientBalance"].ID.Bytes()[:4]) {
		return testToken.UnpackERC20InsufficientBalanceError(raw[4:])
	}
	if bytes.Equal(raw[:4], testToken.abi.Errors["ERC20InvalidApprover"].ID.Bytes()[:4]) {
		return testToken.UnpackERC20InvalidApproverError(raw[4:])
	}
	if bytes.Equal(raw[:4], testToken.abi.Errors["ERC20InvalidReceiver"].ID.Bytes()[:4]) {
		return testToken.UnpackERC20InvalidReceiverError(raw[4:])
	}
	if bytes.Equal(raw[:4], testToken.abi.Errors["ERC20InvalidSender"].ID.Bytes()[:4]) {
		return testToken.UnpackERC20InvalidSenderError(raw[4:])
	}
	if bytes.Equal(raw[:4], testToken.abi.Errors["ERC20InvalidSpender"].ID.Bytes()[:4]) {
		return testToken.UnpackERC20InvalidSpenderError(raw[4:])
	}
	return nil, errors.New("Unknown error")
}

// TestTokenERC20InsufficientAllowance represents a ERC20InsufficientAllowance error raised by the TestToken contract.
type TestTokenERC20InsufficientAllowance struct {
	Spender   common.Address
	Allowance *big.Int
	Needed    *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)
func TestTokenERC20InsufficientAllowanceErrorID() common.Hash {
	return common.HexToHash("0xfb8f41b23e99d2101d86da76cdfa87dd51c82ed07d3cb62cbc473e469dbc75c3")
}

// UnpackERC20InsufficientAllowanceError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)
func (testToken *TestToken) UnpackERC20InsufficientAllowanceError(raw []byte) (*TestTokenERC20InsufficientAllowance, error) {
	out := new(TestTokenERC20InsufficientAllowance)
	if err := testToken.abi.UnpackIntoInterface(out, "ERC20InsufficientAllowance", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// TestTokenERC20InsufficientBalance represents a ERC20InsufficientBalance error raised by the TestToken contract.
type TestTokenERC20InsufficientBalance struct {
	Sender  common.Address
	Balance *big.Int
	Needed  *big.Int
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)
func TestTokenERC20InsufficientBalanceErrorID() common.Hash {
	return common.HexToHash("0xe450d38cd8d9f7d95077d567d60ed49c7254716e6ad08fc9872816c97e0ffec6")
}

// UnpackERC20InsufficientBalanceError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)
func (testToken *TestToken) UnpackERC20InsufficientBalanceError(raw []byte) (*TestTokenERC20InsufficientBalance, error) {
	out := new(TestTokenERC20InsufficientBalance)
	if err := testToken.abi.UnpackIntoInterface(out, "ERC20InsufficientBalance", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// TestTokenERC20InvalidApprover represents a ERC20InvalidApprover error raised by the TestToken contract.
type TestTokenERC20InvalidApprover struct {
	Approver common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidApprover(address approver)
func TestTokenERC20InvalidApproverErrorID() common.Hash {
	return common.HexToHash("0xe602df05cc75712490294c6c104ab7c17f4030363910a7a2626411c6d3118847")
}

// UnpackERC20InvalidApproverError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidApprover(address approver)
func (testToken *TestToken) UnpackERC20InvalidApproverError(raw []byte) (*TestTokenERC20InvalidApprover, error) {
	out := new(TestTokenERC20InvalidApprover)
	if err := testToken.abi.UnpackIntoInterface(out, "ERC20InvalidApprover", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// TestTokenERC20InvalidReceiver represents a ERC20InvalidReceiver error raised by the TestToken contract.
type TestTokenERC20InvalidReceiver struct {
	Receiver common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidReceiver(address receiver)
func TestTokenERC20InvalidReceiverErrorID() common.Hash {
	return common.HexToHash("0xec442f055133b72f3b2f9f0bb351c406b178527de2040a7d1feb4e058771f613")
}

// UnpackERC20InvalidReceiverError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidReceiver(address receiver)
func (testToken *TestToken) UnpackERC20InvalidReceiverError(raw []byte) (*TestTokenERC20InvalidReceiver, error) {
	out := new(TestTokenERC20InvalidReceiver)
	if err := testToken.abi.UnpackIntoInterface(out, "ERC20InvalidReceiver", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// TestTokenERC20InvalidSender represents a ERC20InvalidSender error raised by the TestToken contract.
type TestTokenERC20InvalidSender struct {
	Sender common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidSender(address sender)
func TestTokenERC20InvalidSenderErrorID() common.Hash {
	return common.HexToHash("0x96c6fd1edd0cd6ef7ff0ecc0facdf53148dc0048b57fe58af65755250a7a96bd")
}

// UnpackERC20InvalidSenderError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidSender(address sender)
func (testToken *TestToken) UnpackERC20InvalidSenderError(raw []byte) (*TestTokenERC20InvalidSender, error) {
	out := new(TestTokenERC20InvalidSender)
	if err := testToken.abi.UnpackIntoInterface(out, "ERC20InvalidSender", raw); err != nil {
		return nil, err
	}
	return out, nil
}

// TestTokenERC20InvalidSpender represents a ERC20InvalidSpender error raised by the TestToken contract.
type TestTokenERC20InvalidSpender struct {
	Spender common.Address
}

// ErrorID returns the hash of canonical representation of the error's signature.
//
// Solidity: error ERC20InvalidSpender(address spender)
func TestTokenERC20InvalidSpenderErrorID() common.Hash {
	return common.HexToHash("0x94280d62c347d8d9f4d59a76ea321452406db88df38e0c9da304f58b57b373a2")
}

// UnpackERC20InvalidSpenderError is the Go binding used to decode the provided
// error data into the corresponding Go error struct.
//
// Solidity: error ERC20InvalidSpender(address spender)
func (testToken *TestToken) UnpackERC20InvalidSpenderError(raw []byte) (*TestTokenERC20InvalidSpender, error) {
	out := new(TestTokenERC20InvalidSpender)
	if err := testToken.abi.UnpackIntoInterface(out, "ERC20InvalidSpender", raw); err != nil {
		return nil, err
	}
	return out, nil
}
