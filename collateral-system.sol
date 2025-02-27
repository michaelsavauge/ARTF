// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title ArtCollateralSystem
 * @dev Manages the tokenized fine art collateral backing the stablecoin
 * Features:
 * - Tracks art assets used as collateral
 * - Validates collateralization ratio
 * - Handles liquidation and redemption processes
 */
contract ArtCollateralSystem is 
    Initializable, 
    AccessControlUpgradeable, 
    UUPSUpgradeable 
{
    using SafeMath for uint256;
    
    // Roles for access control
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant ART_MANAGER_ROLE = keccak256("ART_MANAGER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant STABLECOIN_ROLE = keccak256("STABLECOIN_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    
    // Stablecoin contract address
    address public stablecoin;
    
    // Oracle address for art valuations and EUR rate
    address public oracle;
    
    // Art NFT contract address
    address public artNFTContract;
    
    // Minimum collateralization ratio (expressed as percentage, e.g., 150 = 150%)
    uint256 public requiredCollateralRatio;
    
    // Current total value of collateral in EUR (scaled by 10^18)
    uint256 public totalCollateralValueInEUR;
    
    // Current total stablecoin supply
    uint256 public totalStablecoinSupply;
    
    // Struct to represent an art piece
    struct ArtAsset {
        uint256 tokenId;       // NFT token ID
        string title;          // Artwork title
        string artist;         // Artist name
        uint256 appraisalValue; // Current appraisal value in EUR (scaled by 10^18)
        uint256 lastAppraisal; // Timestamp of last appraisal
        bool isActive;         // Whether this asset is currently used as collateral
    }
    
    // Mapping from NFT token ID to art asset
    mapping(uint256 => ArtAsset) public artAssets;
    
    // Array to keep track of all art asset token IDs
    uint256[] public artAssetIds;
    
    // Events
    event ArtAssetAdded(uint256 indexed tokenId, string title, string artist, uint256 appraisalValue);
    event ArtAssetRemoved(uint256 indexed tokenId);
    event ArtAssetReappraised(uint256 indexed tokenId, uint256 newAppraisalValue);
    event CollateralRatioUpdated(uint256 newRatio);
    event StablecoinAddressUpdated(address indexed newStablecoin);
    event OracleAddressUpdated(address indexed newOracle);
    event ArtNFTContractUpdated(address indexed newArtNFTContract);
    event AssetLiquidated(uint256 indexed tokenId, address liquidator, uint256 amount);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initializes the contract with initial configuration
     * @param initialGovernance Initial governance address
     * @param _oracle Oracle address for valuations
     * @param _artNFTContract Address of the art NFT contract
     * @param _requiredCollateralRatio Initial required collateralization ratio
     */
    function initialize(
        address initialGovernance,
        address _oracle,
        address _artNFTContract,
        uint256 _requiredCollateralRatio
    ) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialGovernance);
        _grantRole(GOVERNANCE_ROLE, initialGovernance);
        _grantRole(ART_MANAGER_ROLE, initialGovernance);
        _grantRole(UPGRADER_ROLE, initialGovernance);
        _grantRole(LIQUIDATOR_ROLE, initialGovernance);
        
        oracle = _oracle;
        artNFTContract = _artNFTContract;
        requiredCollateralRatio = _requiredCollateralRatio;
        
        totalCollateralValueInEUR = 0;
        totalStablecoinSupply = 0;
    }
    
    /**
     * @dev Set the stablecoin contract address (can only be set once)
     * @param _stablecoin Address of the stablecoin contract
     */
    function setStablecoin(address _stablecoin) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        require(stablecoin == address(0), "Stablecoin address already set");
        stablecoin = _stablecoin;
        _grantRole(STABLECOIN_ROLE, _stablecoin);
        emit StablecoinAddressUpdated(_stablecoin);
    }
    
    /**
     * @dev Add an art asset as collateral
     * @param tokenId NFT token ID of the artwork
     * @param title Title of the artwork
     * @param artist Artist of the artwork
     * @param appraisalValue Initial appraisal value in EUR (scaled by 10^18)
     */
    function addArtAsset(
        uint256 tokenId,
        string memory title,
        string memory artist,
        uint256 appraisalValue
    ) external onlyRole(ART_MANAGER_ROLE) {
        require(!artAssets[tokenId].isActive, "Art asset already exists");
        
        // Transfer the NFT to this contract
        IERC721(artNFTContract).transferFrom(msg.sender, address(this), tokenId);
        
        // Create and store the art asset
        artAssets[tokenId] = ArtAsset({
            tokenId: tokenId,
            title: title,
            artist: artist,
            appraisalValue: appraisalValue,
            lastAppraisal: block.timestamp,
            isActive: true
        });
        
        artAssetIds.push(tokenId);
        
        // Update total collateral value
        totalCollateralValueInEUR = totalCollateralValueInEUR.add(appraisalValue);
        
        emit ArtAssetAdded(tokenId, title, artist, appraisalValue);
    }
    
    /**
     * @dev Remove an art asset from collateral
     * @param tokenId NFT token ID of the artwork to remove
     * @param recipient Address to receive the NFT
     */
    function removeArtAsset(uint256 tokenId, address recipient)
        external
        onlyRole(ART_MANAGER_ROLE)
    {
        require(artAssets[tokenId].isActive, "Art asset not active");
        
        // Check that removing this asset won't make the system undercollateralized
        uint256 newTotalCollateralValue = totalCollateralValueInEUR.sub(artAssets[tokenId].appraisalValue);
        uint256 requiredCollateral = totalStablecoinSupply.mul(requiredCollateralRatio).div(100);
        require(
            newTotalCollateralValue >= requiredCollateral,
            "Removing asset would make system undercollateralized"
        );
        
        // Update total collateral value
        totalCollateralValueInEUR = newTotalCollateralValue;
        
        // Mark as inactive
        artAssets[tokenId].isActive = false;
        
        // Transfer the NFT back
        IERC721(artNFTContract).transferFrom(address(this), recipient, tokenId);
        
        emit ArtAssetRemoved(tokenId);
    }
    
    /**
     * @dev Update the appraisal value of an art asset (uses oracle data)
     * @param tokenId NFT token ID of the artwork
     */
    function updateArtAssetAppraisal(uint256 tokenId)
        external
        onlyRole(ART_MANAGER_ROLE)
    {
        require(artAssets[tokenId].isActive, "Art asset not active");
        
        // Get new appraisal value from oracle
        uint256 oldAppraisalValue = artAssets[tokenId].appraisalValue;
        uint256 newAppraisalValue = IArtOracle(oracle).getArtValueInEUR(tokenId);
        
        // Update asset and total value
        artAssets[tokenId].appraisalValue = newAppraisalValue;
        artAssets[tokenId].lastAppraisal = block.timestamp;
        
        // Adjust total collateral value
        if (newAppraisalValue > oldAppraisalValue) {
            totalCollateralValueInEUR = totalCollateralValueInEUR.add(newAppraisalValue - oldAppraisalValue);
        } else {
            totalCollateralValueInEUR = totalCollateralValueInEUR.sub(oldAppraisalValue - newAppraisalValue);
        }
        
        emit ArtAssetReappraised(tokenId, newAppraisalValue);
    }
    
    /**
     * @dev Check if the system can support minting additional stablecoins
     * @param amountToMint Amount of stablecoins to mint (in base units)
     * @return bool Whether the collateralization remains sufficient after minting
     */
    function checkCollateralization(uint256 amountToMint) 
        external 
        view 
        onlyRole(STABLECOIN_ROLE)
        returns (bool) 
    {
        uint256 newTotalSupply = totalStablecoinSupply.add(amountToMint);
        uint256 requiredCollateral = newTotalSupply.mul(requiredCollateralRatio).div(100);
        
        return totalCollateralValueInEUR >= requiredCollateral;
    }
    
    /**
     * @dev Notify the system about burned stablecoins
     * @param amountBurned Amount of stablecoins burned
     */
    function notifyBurn(uint256 amountBurned) 
        external 
        onlyRole(STABLECOIN_ROLE) 
    {
        totalStablecoinSupply = totalStablecoinSupply.sub(amountBurned);
    }
    
    /**
     * @dev Update the stablecoin supply (synchronized with actual supply)
     * @param newSupply New total supply
     */
    function updateStablecoinSupply(uint256 newSupply) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        totalStablecoinSupply = newSupply;
    }
    
    /**
     * @dev Liquidate an art asset (in case of emergency or rebalancing)
     * @param tokenId NFT token ID to liquidate
     * @param liquidator Address that will receive the NFT
     * @param stablecoinAmount Amount of stablecoins that will be burned in exchange
     */
    function liquidateArtAsset(
        uint256 tokenId, 
        address liquidator, 
        uint256 stablecoinAmount
    )
        external
        onlyRole(LIQUIDATOR_ROLE)
    {
        require(artAssets[tokenId].isActive, "Art asset not active");
        
        // Transfer the NFT to the liquidator
        IERC721(artNFTContract).transferFrom(address(this), liquidator, tokenId);
        
        // Update collateral value
        totalCollateralValueInEUR = totalCollateralValueInEUR.sub(artAssets[tokenId].appraisalValue);
        
        // Mark as inactive
        artAssets[tokenId].isActive = false;
        
        // Emit liquidation event
        emit AssetLiquidated(tokenId, liquidator, stablecoinAmount);
    }
    
    /**
     * @dev Get the current collateralization ratio
     * @return Current collateralization ratio as a percentage
     */
    function getCurrentCollateralRatio() public view returns (uint256) {
        if (totalStablecoinSupply == 0) {
            return type(uint256).max; // Infinite ratio if no stablecoins exist
        }
        
        return totalCollateralValueInEUR.mul(100).div(totalStablecoinSupply);
    }
    
    /**
     * @dev Get all active art assets
     * @return Array of token IDs for active art assets
     */
    function getActiveArtAssets() external view returns (uint256[] memory) {
        uint256 activeCount = 0;
        
        // Count active assets
        for (uint256 i = 0; i < artAssetIds.length; i++) {
            if (artAssets[artAssetIds[i]].isActive) {
                activeCount++;
            }
        }
        
        // Create array of correct size
        uint256[] memory activeAssets = new uint256[](activeCount);
        
        // Fill array
        uint256 j = 0;
        for (uint256 i = 0; i < artAssetIds.length; i++) {
            if (artAssets[artAssetIds[i]].isActive) {
                activeAssets[j] = artAssetIds[i];
                j++;
            }
        }
        
        return activeAssets;
    }
    
    /**
     * @dev Update the oracle address
     * @param _oracle New oracle address
     */
    function setOracle(address _oracle) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        oracle = _oracle;
        emit OracleAddressUpdated(_oracle);
    }
    
    /**
     * @dev Update the art NFT contract address
     * @param _artNFTContract New art NFT contract address
     */
    function setArtNFTContract(address _artNFTContract) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        artNFTContract = _artNFTContract;
        emit ArtNFTContractUpdated(_artNFTContract);
    }
    
    /**
     * @dev Update the required collateralization ratio
     * @param _requiredCollateralRatio New required ratio
     */
    function setRequiredCollateralRatio(uint256 _requiredCollateralRatio) 
        external 
        onlyRole(GOVERNANCE_ROLE) 
    {
        requiredCollateralRatio = _requiredCollateralRatio;
        emit CollateralRatioUpdated(_requiredCollateralRatio);
    }
    
    /**
     * @dev Required override for UUPS upgradeable contracts
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}
}

// Simple interface for the Art Oracle
interface IArtOracle {
    function getArtValueInEUR(uint256 tokenId) external view returns (uint256);
}

// Simple interface for ERC721
interface IERC721 {
    function transferFrom(address from, address to, uint256 tokenId) external;
}
