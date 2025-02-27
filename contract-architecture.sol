// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title EuroArtCoin
 * @dev Implementation of a Euro-pegged stablecoin backed by tokenized fine art
 * Features:
 * - ERC20 standard compliance with EIP-2612 Permit extension
 * - Controlled mint/burn by governance
 * - Integration with art collateral system
 * - Upgradeability via UUPS pattern
 */
contract EuroArtCoin is 
    Initializable, 
    ERC20Upgradeable, 
    ERC20PermitUpgradeable,
    AccessControlUpgradeable, 
    UUPSUpgradeable 
{
    using SafeMath for uint256;
    
    // Roles for access control
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    
    // Art collateral system address
    address public collateralSystem;
    
    // Oracle address for EUR rate and art valuations
    address public oracle;
    
    // Minimum collateralization ratio (expressed as percentage, e.g., 150 = 150%)
    uint256 public collateralRatio;
    
    // Events
    event CollateralSystemUpdated(address indexed newCollateralSystem);
    event OracleUpdated(address indexed newOracle);
    event CollateralRatioUpdated(uint256 newRatio);
    event TokensMinted(address indexed to, uint256 amount);
    event TokensBurned(address indexed from, uint256 amount);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initializes the contract with initial configuration
     * @param name_ Name of the token
     * @param symbol_ Symbol of the token
     * @param initialGovernance Initial governance address (likely a timelock)
     * @param _collateralSystem Address of the art collateral system
     * @param _oracle Address of the oracle system
     * @param _collateralRatio Initial collateralization ratio (e.g., 150 for 150%)
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address initialGovernance,
        address _collateralSystem,
        address _oracle,
        uint256 _collateralRatio
    ) public initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, initialGovernance);
        _grantRole(MINTER_ROLE, initialGovernance);
        _grantRole(BURNER_ROLE, initialGovernance);
        _grantRole(UPGRADER_ROLE, initialGovernance);
        _grantRole(GOVERNANCE_ROLE, initialGovernance);
        
        collateralSystem = _collateralSystem;
        oracle = _oracle;
        collateralRatio = _collateralRatio;
    }
    
    /**
     * @dev Mint new tokens (only callable by accounts with MINTER_ROLE)
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        // Check with collateral system that there's enough backing
        require(
            ICollateralSystem(collateralSystem).checkCollateralization(amount),
            "EuroArtCoin: Insufficient collateral for mint"
        );
        
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }
    
    /**
     * @dev Burn tokens (only callable by accounts with BURNER_ROLE)
     * @param from Address from which to burn tokens
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
        
        // Notify collateral system about the burn
        ICollateralSystem(collateralSystem).notifyBurn(amount);
        
        emit TokensBurned(from, amount);
    }
    
    /**
     * @dev Update the collateral system address (only by governance)
     * @param _collateralSystem New collateral system address
     */
    function setCollateralSystem(address _collateralSystem) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        collateralSystem = _collateralSystem;
        emit CollateralSystemUpdated(_collateralSystem);
    }
    
    /**
     * @dev Update the oracle address (only by governance)
     * @param _oracle New oracle address
     */
    function setOracle(address _oracle) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        oracle = _oracle;
        emit OracleUpdated(_oracle);
    }
    
    /**
     * @dev Update the collateralization ratio (only by governance)
     * @param _collateralRatio New collateralization ratio
     */
    function setCollateralRatio(uint256 _collateralRatio) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        collateralRatio = _collateralRatio;
        emit CollateralRatioUpdated(_collateralRatio);
    }
    
    /**
     * @dev Required override for UUPS upgradeable contracts
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}
    
    /**
     * @dev Returns the decimals of the token (override to match EUR - 18 decimals)
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

/**
 * @dev Interface for the Collateral System
 */
interface ICollateralSystem {
    function checkCollateralization(uint256 amountToMint) external view returns (bool);
    function notifyBurn(uint256 amountBurned) external;
}
