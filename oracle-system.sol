// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title ArtEuroOracle
 * @dev Provides price feeds for both art valuations and EUR/USD exchange rates
 * Features:
 * - Managed by in-house oracle operators
 * - Provides Euro exchange rates and fine art valuations
 * - Includes trust and verification mechanisms
 */
contract ArtEuroOracle is 
    Initializable, 
    AccessControlUpgradeable, 
    UUPSUpgradeable 
{
    using SafeMath for uint256;
    
    // Access control roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ORACLE_OPERATOR_ROLE = keccak256("ORACLE_OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant ART_APPRAISER_ROLE = keccak256("ART_APPRAISER_ROLE");
    
    // EUR/USD exchange rate (scaled by 10^18)
    uint256 public eurUsdRate;
    
    // Last update timestamp for EUR/USD rate
    uint256 public lastEurUsdRateUpdate;
    
    // Mapping of token IDs to art valuations in EUR (scaled by 10^18)
    mapping(uint256 => uint256) public artValuationsInEur;
    
    // Mapping of token IDs to last valuation timestamp
    mapping(uint256 => uint256) public artValuationTimestamps;
    
    // Maximum allowed time between updates (1 day)
    uint256 public constant MAX_UPDATE_DELAY = 1 days;
    
    // Minimum number of appraisers required for art valuation
    uint256 public minAppraisersRequired;
    
    // Struct to track pending art appraisals
    struct PendingArtAppraisal {
        uint256 tokenId;
        mapping(address => uint256) appraiserValues;
        address[] appraisers;
        uint256 totalValue;
        bool finalized;
    }
    
    // Mapping of token IDs to pending appraisals
    mapping(uint256 => PendingArtAppraisal) public pendingAppraisals;
    
    // Events
    event EurUsdRateUpdated(uint256 rate, uint256 timestamp);
    event ArtValuationUpdated(uint256 indexed tokenId, uint256 valueInEur, uint256 timestamp);
    event ArtAppraisalSubmitted(uint256 indexed tokenId, address appraiser, uint256 valueInEur);
    event ArtAppraisalFinalized(uint256 indexed tokenId, uint256 finalValueInEur);
    event MinAppraisersUpdated(uint256 newMinAppraisers);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @dev Initializes the contract with initial configuration
     * @param initialAdmin Initial admin address
     * @param operators Array of initial oracle operators
     * @param appraisers Array of initial art appraisers
     * @param initialEurUsdRate Initial EUR/USD exchange rate (scaled by 10^18)
     * @param _minAppraisersRequired Minimum number of appraisers required for finalization
     */
    function initialize(
        address initialAdmin,
        address[] memory operators,
        address[] memory appraisers,
        uint256 initialEurUsdRate,
        uint256 _minAppraisersRequired
    ) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ADMIN_ROLE, initialAdmin);
        _grantRole(UPGRADER_ROLE, initialAdmin);
        
        // Grant operator roles
        for (uint256 i = 0; i < operators.length; i++) {
            _grantRole(ORACLE_OPERATOR_ROLE, operators[i]);
        }
        
        // Grant appraiser roles
        for (uint256 i = 0; i < appraisers.length; i++) {
            _grantRole(ART_APPRAISER_ROLE, appraisers[i]);
        }
        
        // Set initial values
        eurUsdRate = initialEurUsdRate;
        lastEurUsdRateUpdate = block.timestamp;
        minAppraisersRequired = _minAppraisersRequired;
    }
    
    /**
     * @dev Update the EUR/USD exchange rate
     * @param newRate New EUR/USD rate (scaled by 10^18)
     */
    function updateEurUsdRate(uint256 newRate)
        external
        onlyRole(ORACLE_OPERATOR_ROLE)
    {
        require(newRate > 0, "Rate must be positive");
        
        eurUsdRate = newRate;
        lastEurUsdRateUpdate = block.timestamp;
        
        emit EurUsdRateUpdated(newRate, block.timestamp);
    }
    
    /**
     * @dev Submit an appraisal for an artwork
     * @param tokenId NFT token ID of the artwork
     * @param valueInEur Appraised value in EUR (scaled by 10^18)
     */
    function submitArtAppraisal(uint256 tokenId, uint256 valueInEur)
        external
        onlyRole(ART_APPRAISER_ROLE)
    {
        require(valueInEur > 0, "Value must be positive");
        
        // Initialize the pending appraisal if not already
        if (pendingAppraisals[tokenId].appraisers.length == 0) {
            pendingAppraisals[tokenId].tokenId = tokenId;
            pendingAppraisals[tokenId].totalValue = 0;
            pendingAppraisals[tokenId].finalized = false;
        }
        
        // Check if this appraiser has already submitted
        bool alreadySubmitted = false;
        for (uint256 i = 0; i < pendingAppraisals[tokenId].appraisers.length; i++) {
            if (pendingAppraisals[tokenId].appraisers[i] == msg.sender) {
                alreadySubmitted = true;
                break;
            }
        }
        
        if (!alreadySubmitted) {
            pendingAppraisals[tokenId].appraisers.push(msg.sender);
        } else {
            // Subtract previous value from total
            pendingAppraisals[