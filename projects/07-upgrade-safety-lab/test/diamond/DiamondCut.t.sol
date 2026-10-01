// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DiamondInit} from "../../src/diamond/DiamondInit.sol";
import {RegistryDiamond} from "../../src/diamond/RegistryDiamond.sol";
import {AdminFacet} from "../../src/diamond/facets/AdminFacet.sol";
import {DiamondCutFacet} from "../../src/diamond/facets/DiamondCutFacet.sol";
import {IDiamondCut, IERC8109Introspection} from "../../src/diamond/interfaces/IDiamond.sol";
import {LibDiamond} from "../../src/diamond/libraries/LibDiamond.sol";
import {LibOwnership} from "../../src/diamond/libraries/LibOwnership.sol";
import {ISubscriptionRegistry} from "../../src/interfaces/IRegistry.sol";
import {ClashFacetA, ClashFacetB, DuplicateOwnerFacet} from "../layout/fixtures/ClashFacets.sol";
import {LabBase} from "../utils/LabBase.sol";
import {MockERC20} from "../utils/Mocks.sol";

/// @notice Facet that adds a brand-new function.
contract GreeterFacet {
    function greet() external pure returns (string memory) {
        return "hello from a new facet";
    }
}

/// @notice Replacement for `AdminFacet.version`, proving Replace swaps logic while namespaced state stays.
contract AdminFacetV2 {
    function version() external pure returns (string memory) {
        return "diamond-2.0.0";
    }
}

/// @notice Initializer that always fails, to check revert bubbling.
contract RevertingInit {
    error InitBoom(uint256 code);

    function init() external pure {
        revert InitBoom(7);
    }
}

/// @notice Initializer that writes a marker through the diamond's context.
contract MarkerInit {
    event Marked(address diamond);

    function mark() external {
        emit Marked(address(this));
    }
}

/// @notice Exposes LibDiamond's constructor-only helper so its duplicate guard can be unit-tested.
contract LibDiamondHarness {
    function registerImmutable(bytes4[] memory selectors) external {
        LibDiamond.addImmutableFunctions(selectors);
    }
}

/// @notice ERC-2535 cut semantics with ERC-8109 events, every revert path included.
contract DiamondCutTest is LabBase {
    RegistryDiamond internal diamond;
    DiamondFacets internal f;
    MockERC20 internal token;
    address internal stranger = makeAddr("stranger");

    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);
    event DiamondFunctionAdded(bytes4 indexed _selector, address indexed _facet);
    event DiamondFunctionReplaced(bytes4 indexed _selector, address indexed _oldFacet, address indexed _newFacet);
    event DiamondFunctionRemoved(bytes4 indexed _selector, address indexed _oldFacet);
    event DiamondDelegateCall(address indexed _delegate, bytes _delegateCalldata);

    function setUp() public {
        token = _newToken();
        (diamond, f) = _deployDiamond(owner, token, treasury);
    }

    function _one(bytes4 selector) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = selector;
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory selectors)
        internal
        returns (bool ok, bytes memory ret)
    {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(facet, action, selectors);
        vm.prank(owner);
        (ok, ret) = address(diamond).call(abi.encodeCall(IDiamondCut.diamondCut, (cuts, address(0), "")));
    }

    function _cutExpectRevert(
        address facet,
        IDiamondCut.FacetCutAction action,
        bytes4[] memory selectors,
        bytes memory err
    ) internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(facet, action, selectors);
        vm.expectRevert(err);
        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_rejectsZeroOwner() public {
        DiamondFacets memory g = _deployFacets();
        IDiamondCut.FacetCut[] memory cuts = _facetCuts(g);
        vm.expectRevert(abi.encodeWithSelector(LibOwnership.OwnableInvalidOwner.selector, address(0)));
        new RegistryDiamond(address(0), cuts, address(0), "");
    }

    function test_constructor_registersImmutableIntrospection() public view {
        assertEq(diamond.facetAddress(IERC8109Introspection.facetAddress.selector), address(diamond));
        assertEq(diamond.facetAddress(IERC8109Introspection.functionFacetPairs.selector), address(diamond));
        assertEq(ISubscriptionRegistry(address(diamond)).owner(), owner);
    }

    // ------------------------------------------------------------------ add

    function test_add_newFacetEmitsPerFunctionAndCutEvents() public {
        GreeterFacet greeter = new GreeterFacet();
        bytes4[] memory selectors = _one(GreeterFacet.greet.selector);
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(greeter), IDiamondCut.FacetCutAction.Add, selectors);

        vm.expectEmit(address(diamond));
        emit DiamondFunctionAdded(GreeterFacet.greet.selector, address(greeter));
        vm.expectEmit(address(diamond));
        emit DiamondCut(cuts, address(0), "");
        vm.prank(owner);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        assertEq(GreeterFacet(address(diamond)).greet(), "hello from a new facet");
        assertEq(diamond.facetAddress(GreeterFacet.greet.selector), address(greeter));
    }

    function test_add_rejectsExistingSelector() public {
        DuplicateOwnerFacet dup = new DuplicateOwnerFacet();
        _cutExpectRevert(
            address(dup),
            IDiamondCut.FacetCutAction.Add,
            _one(DuplicateOwnerFacet.owner.selector),
            abi.encodeWithSelector(
                LibDiamond.SelectorAlreadyExists.selector, DuplicateOwnerFacet.owner.selector, address(f.ownership)
            )
        );
    }

    function test_add_rejectsImmutableSelector() public {
        GreeterFacet greeter = new GreeterFacet();
        bytes4 sel = IERC8109Introspection.functionFacetPairs.selector;
        _cutExpectRevert(
            address(greeter),
            IDiamondCut.FacetCutAction.Add,
            _one(sel),
            abi.encodeWithSelector(LibDiamond.SelectorAlreadyExists.selector, sel, address(diamond))
        );
    }

    function test_add_rejectsFacetWithoutCodeAndTheDiamondItself() public {
        _cutExpectRevert(
            stranger,
            IDiamondCut.FacetCutAction.Add,
            _one(GreeterFacet.greet.selector),
            abi.encodeWithSelector(LibDiamond.InvalidFacet.selector, stranger)
        );
        _cutExpectRevert(
            address(diamond),
            IDiamondCut.FacetCutAction.Add,
            _one(GreeterFacet.greet.selector),
            abi.encodeWithSelector(LibDiamond.InvalidFacet.selector, address(diamond))
        );
    }

    function test_cut_rejectsEmptySelectorList() public {
        GreeterFacet greeter = new GreeterFacet();
        _cutExpectRevert(
            address(greeter),
            IDiamondCut.FacetCutAction.Add,
            new bytes4[](0),
            abi.encodeWithSelector(LibDiamond.EmptySelectorList.selector, address(greeter))
        );
    }

    function test_add_true4ByteCollisionIsRejected() public {
        ClashFacetA a = new ClashFacetA();
        ClashFacetB b = new ClashFacetB();
        assertEq(ClashFacetA.burn.selector, ClashFacetB.collate_propagate_storage.selector);
        (bool ok,) = _cut(address(a), IDiamondCut.FacetCutAction.Add, _one(ClashFacetA.burn.selector));
        assertTrue(ok);
        _cutExpectRevert(
            address(b),
            IDiamondCut.FacetCutAction.Add,
            _one(ClashFacetB.collate_propagate_storage.selector),
            abi.encodeWithSelector(LibDiamond.SelectorAlreadyExists.selector, bytes4(0x42966c68), address(a))
        );
        // The diamond keeps routing the selector to the first facet.
        assertEq(ClashFacetA(address(diamond)).burn(1), "A.burn");
    }

    // ------------------------------------------------------------------ replace

    function test_replace_swapsLogicAndKeepsState() public {
        vm.prank(owner);
        ISubscriptionRegistry(address(diamond)).setGracePeriod(1 days);
        AdminFacetV2 v2 = new AdminFacetV2();
        bytes4[] memory selectors = _one(AdminFacet.version.selector);

        vm.expectEmit(address(diamond));
        emit DiamondFunctionReplaced(AdminFacet.version.selector, address(f.admin), address(v2));
        (bool ok,) = _cut(address(v2), IDiamondCut.FacetCutAction.Replace, selectors);
        assertTrue(ok);

        assertEq(ISubscriptionRegistry(address(diamond)).version(), "diamond-2.0.0");
        assertEq(ISubscriptionRegistry(address(diamond)).gracePeriod(), 1 days, "namespaced state survives");
    }

    function test_replace_rejectsUnknownSameFacetAndImmutable() public {
        AdminFacetV2 v2 = new AdminFacetV2();
        _cutExpectRevert(
            address(v2),
            IDiamondCut.FacetCutAction.Replace,
            _one(GreeterFacet.greet.selector),
            abi.encodeWithSelector(LibDiamond.SelectorNotFound.selector, GreeterFacet.greet.selector)
        );
        _cutExpectRevert(
            address(f.admin),
            IDiamondCut.FacetCutAction.Replace,
            _one(AdminFacet.version.selector),
            abi.encodeWithSelector(
                LibDiamond.ReplaceWithSameFacet.selector, AdminFacet.version.selector, address(f.admin)
            )
        );
        bytes4 immutableSel = IERC8109Introspection.facetAddress.selector;
        _cutExpectRevert(
            address(v2),
            IDiamondCut.FacetCutAction.Replace,
            _one(immutableSel),
            abi.encodeWithSelector(LibDiamond.ImmutableFunction.selector, immutableSel)
        );
        _cutExpectRevert(
            stranger,
            IDiamondCut.FacetCutAction.Replace,
            _one(AdminFacet.version.selector),
            abi.encodeWithSelector(LibDiamond.InvalidFacet.selector, stranger)
        );
    }

    // ------------------------------------------------------------------ remove

    function test_remove_unroutesTheSelector() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = AdminFacet.pause.selector;
        selectors[1] = AdminFacet.unpause.selector;
        vm.expectEmit(address(diamond));
        emit DiamondFunctionRemoved(AdminFacet.pause.selector, address(f.admin));
        (bool ok,) = _cut(address(0), IDiamondCut.FacetCutAction.Remove, selectors);
        assertTrue(ok);

        vm.expectRevert(
            abi.encodeWithSelector(IERC8109Introspection.FunctionNotFound.selector, AdminFacet.pause.selector)
        );
        vm.prank(owner);
        ISubscriptionRegistry(address(diamond)).pause();
        assertEq(diamond.facetAddress(AdminFacet.pause.selector), address(0));
    }

    function test_remove_rejectsNonZeroFacetUnknownAndImmutable() public {
        _cutExpectRevert(
            address(f.admin),
            IDiamondCut.FacetCutAction.Remove,
            _one(AdminFacet.pause.selector),
            abi.encodeWithSelector(LibDiamond.RemoveFacetAddressMustBeZero.selector, address(f.admin))
        );
        _cutExpectRevert(
            address(0),
            IDiamondCut.FacetCutAction.Remove,
            _one(GreeterFacet.greet.selector),
            abi.encodeWithSelector(LibDiamond.SelectorNotFound.selector, GreeterFacet.greet.selector)
        );
        bytes4 immutableSel = IERC8109Introspection.functionFacetPairs.selector;
        _cutExpectRevert(
            address(0),
            IDiamondCut.FacetCutAction.Remove,
            _one(immutableSel),
            abi.encodeWithSelector(LibDiamond.ImmutableFunction.selector, immutableSel)
        );
    }

    function test_removingDiamondCutFreezesTheDiamond() public {
        (bool ok,) = _cut(address(0), IDiamondCut.FacetCutAction.Remove, _one(DiamondCutFacet.diamondCut.selector));
        assertTrue(ok);
        (ok,) = _cut(address(new GreeterFacet()), IDiamondCut.FacetCutAction.Add, _one(GreeterFacet.greet.selector));
        assertFalse(ok);
        _cutExpectRevert(
            address(new GreeterFacet()),
            IDiamondCut.FacetCutAction.Add,
            _one(GreeterFacet.greet.selector),
            abi.encodeWithSelector(IERC8109Introspection.FunctionNotFound.selector, DiamondCutFacet.diamondCut.selector)
        );
    }

    // ------------------------------------------------------------------ init + access

    function test_init_semantics() public {
        IDiamondCut.FacetCut[] memory none = new IDiamondCut.FacetCut[](0);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.InitCalldataWithoutInit.selector, 4));
        IDiamondCut(address(diamond)).diamondCut(none, address(0), hex"deadbeef");

        vm.expectRevert(abi.encodeWithSelector(LibDiamond.InitHasNoCode.selector, stranger));
        IDiamondCut(address(diamond)).diamondCut(none, stranger, hex"deadbeef");

        RevertingInit bad = new RevertingInit();
        vm.expectRevert(abi.encodeWithSelector(RevertingInit.InitBoom.selector, 7));
        IDiamondCut(address(diamond)).diamondCut(none, address(bad), abi.encodeCall(RevertingInit.init, ()));

        MarkerInit marker = new MarkerInit();
        bytes memory data = abi.encodeCall(MarkerInit.mark, ());
        vm.expectEmit(address(diamond));
        emit DiamondDelegateCall(address(marker), data);
        vm.expectEmit(address(diamond));
        emit MarkerInit.Marked(address(diamond));
        IDiamondCut(address(diamond)).diamondCut(none, address(marker), data);

        // DiamondInit is one-shot.
        vm.expectRevert(abi.encodeWithSelector(DiamondInit.AlreadyInitialized.selector, address(token)));
        IDiamondCut(address(diamond))
            .diamondCut(none, address(f.init), abi.encodeCall(DiamondInit.init, (token, treasury)));
        vm.stopPrank();
    }

    function test_diamondInit_validatesInputs() public {
        DiamondFacets memory g = _deployFacets();
        IDiamondCut.FacetCut[] memory cuts = _facetCuts(g);
        vm.expectRevert(abi.encodeWithSignature("InvalidPaymentToken(address)", stranger));
        new RegistryDiamond(
            owner, cuts, address(g.init), abi.encodeCall(DiamondInit.init, (MockERC20(stranger), treasury))
        );
        vm.expectRevert(abi.encodeWithSignature("InvalidTreasury(address)", address(0)));
        new RegistryDiamond(owner, cuts, address(g.init), abi.encodeCall(DiamondInit.init, (token, address(0))));
    }

    function test_diamondInit_viaLaterCut_validatesTreasury() public {
        DiamondFacets memory g = _deployFacets();
        RegistryDiamond fresh = new RegistryDiamond(owner, _facetCuts(g), address(0), "");
        IDiamondCut.FacetCut[] memory none = new IDiamondCut.FacetCut[](0);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSignature("InvalidTreasury(address)", address(0)));
        IDiamondCut(address(fresh))
            .diamondCut(none, address(g.init), abi.encodeCall(DiamondInit.init, (token, address(0))));
        IDiamondCut(address(fresh))
            .diamondCut(none, address(g.init), abi.encodeCall(DiamondInit.init, (token, treasury)));
        vm.stopPrank();
        assertEq(ISubscriptionRegistry(address(fresh)).paymentToken(), address(token));
    }

    function test_immutableRegistration_rejectsDuplicates() public {
        LibDiamondHarness harness = new LibDiamondHarness();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = bytes4(0x11111111);
        selectors[1] = bytes4(0x11111111);
        vm.expectRevert(
            abi.encodeWithSelector(LibDiamond.SelectorAlreadyExists.selector, bytes4(0x11111111), address(harness))
        );
        harness.registerImmutable(selectors);
    }

    function test_cut_onlyOwner() public {
        IDiamondCut.FacetCut[] memory none = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(abi.encodeWithSelector(LibOwnership.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        IDiamondCut(address(diamond)).diamondCut(none, address(0), "");
    }

    function test_fallback_unknownSelectorAndPlainEther() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC8109Introspection.FunctionNotFound.selector, GreeterFacet.greet.selector)
        );
        GreeterFacet(address(diamond)).greet();

        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(diamond).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IERC8109Introspection.FunctionNotFound.selector, bytes4(0)));
    }

    function test_facetsCalledDirectlyCannotBeHijacked() public {
        // A facet called outside the diamond sees its own (empty) storage: no owner, so no cut.
        IDiamondCut.FacetCut[] memory none = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(abi.encodeWithSelector(LibOwnership.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        f.cut.diamondCut(none, address(0), "");
    }
}
