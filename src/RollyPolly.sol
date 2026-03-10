// SPDX-License-Identifier: MIT
pragma solidity >=0.8.27;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";


//smart-contract\lib\openzeppelin-contracts\contracts\utils\ReentrancyGuard.sol
import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";


/**
 * @title Rolly Polly
 * @notice Illiquid, Priceless Private Prediction Markets using .
 *
 *         Users submit encrypted positions (YES/NO direction) with USDC stakes.
 *         During the market lifetime, no one can see which side is winning.
 *
 *         Multi-Agent System: Each user can deploy multiple autonomous agents,
 *         each with its own USDC vault, guardrails, system prompt, and optional
 *         delegate address for auto-execution without wallet popups.
 *
 *         At resolution time, BITE v2 CTX decryption reveals all positions
 *         atomically and distributes parimutuel payouts.
 */
contract BeliefMarket is  ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    // ─── Constants ────────────────────────────────────────────────────
  
    uint256 public constant MAX_POSITIONS_PER_MARKET = 20;
   
    uint256 public constant REFUND_GRACE_PERIOD = 7 days;
    uint256 public constant MAX_AGENTS_PER_USER = 10;

    // Asset type bitmask values
    uint8 public constant ASSET_COMMODITY = 1;  // 0b001
    uint8 public constant ASSET_ETF = 2;        // 0b010
    uint8 public constant ASSET_FX = 4;         // 0b100

    // Personality constants
    uint8 public constant PERSONALITY_CONSERVATIVE = 0;
    uint8 public constant PERSONALITY_BALANCED = 1;
    uint8 public constant PERSONALITY_AGGRESSIVE = 2;
    uint8 public constant PERSONALITY_CONTRARIAN = 3;

    // ─── Immutables ──────────────────────────────────────────────────
    IERC20 public immutable usdc;

    // ─── Enums ───────────────────────────────────────────────────────
    enum MarketStatus {
        OPEN,
        RESOLVING,
        SETTLED,
        CANCELLED
    }

    enum PositionStatus {
        ACTIVE,
        SETTLED,
        CANCELLED,
        REFUNDED
    }

    // ─── Structs ─────────────────────────────────────────────────────

    struct Market {
        address creator;
        uint256 dataSourceId;
        uint256 targetPrice;
        bool conditionAbove;
        uint8 assetType;
        uint256 resolutionTime;
        uint256 totalDeposits;
        uint256 totalPositions;
        MarketStatus status;
        bool outcome;
        uint256 yesPool;
        uint256 noPool;
    }

    struct Position {
        address trader;          // Owner or delegate who submitted
        uint256 agentId;         // 0 = direct user position, >0 = agent position
        uint256 marketId;
        uint256 deposit;
      bytes32 commitment;
        bool direction;
        PositionStatus status;
        uint256 payout;
        
        bool revealed;
      
    }

    struct AgentConfig {
        address owner;              // User who created this agent
        address delegate;           // Browser-generated wallet for auto-execution
        string name;                // Display name
        string systemPrompt;        // Natural-language instructions for behavior
        uint8 personality;          // 0=conservative, 1=balanced, 2=aggressive, 3=contrarian
        uint256 balance;            // USDC vault balance
        uint256 maxBetPerMarket;    // Max USDC per single position
        uint256 maxTotalExposure;   // Max USDC across all active positions
        uint256 currentExposure;    // Running total of active deposits
        uint8 allowedAssetTypes;    // Bitmask of allowed asset types
        uint8 confidenceThreshold;  // 0-100, minimum confidence to act
        bool autoExecute;           // true = auto, false = manual approval
        bool isActive;
    }

    // ─── State ───────────────────────────────────────────────────────

    // Markets
    uint256 public nextMarketId;
    mapping(uint256 => Market) public markets;

    // Positions
    uint256 public nextPositionId;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => uint256[]) public marketPositionIds;
    mapping(address => uint256[]) public userPositionIds;

    // Multi-Agent
    uint256 public nextAgentId;
    mapping(uint256 => AgentConfig) public agents;
    mapping(address => uint256[]) public ownerAgentIds;
    mapping(address => uint256) public delegateToAgentId;

    // Agent -> position IDs (for tracking)
    mapping(uint256 => uint256[]) public agentPositionIds;

    // ─── Events ──────────────────────────────────────────────────────

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        uint256 dataSourceId,
        uint256 targetPrice,
        bool conditionAbove,
        uint8 assetType,
        uint256 resolutionTime
    );

    event PositionSubmitted(
        uint256 indexed positionId,
        uint256 indexed marketId,
        address indexed trader,
        uint256 agentId,
        uint256 deposit
    );

    event PositionCancelled(
        uint256 indexed positionId,
        address indexed trader,
        uint256 refundAmount
    );

    event MarketResolutionTriggered(
        uint256 indexed marketId,
        bool outcome,
        address triggeredBy
    );

    event MarketSettled(
        uint256 indexed marketId,
        bool outcome,
        uint256 yesPool,
        uint256 noPool,
        uint256 totalPositions
    );

    event PositionSettled(
        uint256 indexed positionId,
        uint256 indexed marketId,
        address indexed trader,
        bool direction,
        uint256 deposit,
        uint256 payout
    );

    event MarketRefunded(uint256 indexed marketId, uint256 totalRefunded);

    event AgentCreated(
        uint256 indexed agentId,
        address indexed owner,
        address delegate,
        string name,
        uint8 personality
    );

    event AgentUpdated(uint256 indexed agentId, address indexed owner);
    event AgentFunded(uint256 indexed agentId, uint256 amount, uint256 newBalance);
    event AgentWithdrawal(uint256 indexed agentId, uint256 amount, uint256 newBalance);
    event AgentDeactivated(uint256 indexed agentId);
    event AgentActivated(uint256 indexed agentId);
    event PositionRevealed(uint256 indexed positionId,bool direction);


    // ─── Errors ──────────────────────────────────────────────────────

    error MarketNotOpen();
    error MarketNotFound();
    error MarketFull();
    error InvalidDeposit();
    error InvalidResolutionTime();
    // error InvalidEncryptedData();
    error NotMarketCreator();
    error ResolutionTooEarly();
    error PositionNotFound();
    error NotPositionOwner();
    error PositionNotActive();
    // error InsufficientCTXPayment();
    error RefundTooEarly();
    error AgentNotFound();
    error AgentNotActive();
    error AgentNotAuthorized();
    error AgentBetExceedsMax();
    error AgentExposureExceeded();
    error AgentAssetTypeNotAllowed();
    error AgentInsufficientBalance();
    error AgentLimitReached();
    error InsufficientWithdrawBalance();

    // ─── Constructor ─────────────────────────────────────────────────

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
        nextAgentId = 1; // Reserve 0 for "no agent" (direct user positions)
    }


   function revealPosition(
    uint256 _positionId,
    bool _direction,
    bytes32 _salt
) external nonReentrant {
    Position storage pos = positions[_positionId];   // ← yahan "positions" tha, tumne "position" likha tha (typo)
    
    if (pos.revealed) revert("Position Already Revealed");
    if (keccak256(abi.encodePacked(_direction, _salt)) != pos.commitment) 
        revert("Invalid reveal");

    pos.direction = _direction;
    pos.revealed = true;

    emit PositionRevealed(_positionId, _direction); // optional event add kar sakte ho
}

    // ═══════════════════════════════════════════════════════════════════
    // Market Creation
    // ═══════════════════════════════════════════════════════════════════

    function createMarket(
        uint256 _dataSourceId,
        uint256 _targetPrice,
        bool _conditionAbove,
        uint8 _assetType,
        uint256 _resolutionTime
    ) external returns (uint256 marketId) {
        if (_resolutionTime <= block.timestamp) revert InvalidResolutionTime();

        marketId = nextMarketId++;
        markets[marketId] = Market({
            creator: msg.sender,
            dataSourceId: _dataSourceId,
            targetPrice: _targetPrice,
            conditionAbove: _conditionAbove,
            assetType: _assetType,
            resolutionTime: _resolutionTime,
            totalDeposits: 0,
            totalPositions: 0,
            status: MarketStatus.OPEN,
            outcome: false,
            yesPool: 0,
            noPool: 0
        });

        emit MarketCreated(
            marketId, msg.sender, _dataSourceId,
            _targetPrice, _conditionAbove, _assetType, _resolutionTime
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Direct Position Submission (user wallet, no agent)
    // ═══════════════════════════════════════════════════════════════════

    function submitPosition(
    uint256 _marketId,
    bytes32 _commitment,      // ← bytes calldata _encryptedDirection ki jagah yeh
    uint256 _deposit
) external nonReentrant returns (uint256 positionId) {
    Market storage market = markets[_marketId];
    if (market.creator == address(0)) revert MarketNotFound();
    if (market.status != MarketStatus.OPEN) revert MarketNotOpen();
    if (block.timestamp >= market.resolutionTime) revert MarketNotOpen();
    if (marketPositionIds[_marketId].length >= MAX_POSITIONS_PER_MARKET) revert MarketFull();
    if (_deposit == 0) revert InvalidDeposit();
    if (_commitment == bytes32(0)) revert("Invalid commitment");   // ← naya check

    // Transfer USDC
    usdc.safeTransferFrom(msg.sender, address(this), _deposit);

    positionId = nextPositionId++;
    positions[positionId] = Position({
        trader: msg.sender,
        agentId: 0,
        marketId: _marketId,
        deposit: _deposit,
        commitment: _commitment,     // ← yahan commitment save
        direction: false,            // reveal hone ke baad update hoga
        revealed: false,             // ← naya
        status: PositionStatus.ACTIVE,
        payout: 0
    });

    marketPositionIds[_marketId].push(positionId);
    userPositionIds[msg.sender].push(positionId);

    market.totalDeposits += _deposit;
    market.totalPositions++;

    emit PositionSubmitted(positionId, _marketId, msg.sender, 0, _deposit);
}

    // ═══════════════════════════════════════════════════════════════════
    // Agent Position Submission (from agent vault)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Submit an encrypted position using an agent's vault balance.
     *         Can be called by the agent owner OR the agent's delegate address.
     */
    function submitPositionForAgent(
        uint256 _agentId,
        uint256 _marketId,
        bytes32 _commitment, 
        uint256 _deposit
    ) external nonReentrant returns (uint256 positionId) {
        AgentConfig storage agent = agents[_agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (!agent.isActive) revert AgentNotActive();
        if (msg.sender != agent.owner && msg.sender != agent.delegate) revert AgentNotAuthorized();

        Market storage market = markets[_marketId];
        if (market.creator == address(0)) revert MarketNotFound();
        if (market.status != MarketStatus.OPEN) revert MarketNotOpen();
        if (block.timestamp >= market.resolutionTime) revert MarketNotOpen();
        if (marketPositionIds[_marketId].length >= MAX_POSITIONS_PER_MARKET) revert MarketFull();
        if (_deposit == 0) revert InvalidDeposit();
        

        // Enforce per-agent guardrails
        if (_deposit > agent.maxBetPerMarket) revert AgentBetExceedsMax();
        if (agent.currentExposure + _deposit > agent.maxTotalExposure) revert AgentExposureExceeded();
        if ((market.assetType & agent.allowedAssetTypes) == 0) revert AgentAssetTypeNotAllowed();
        if (agent.balance < _deposit) revert AgentInsufficientBalance();

        // Deduct from agent vault
        agent.balance -= _deposit;
        agent.currentExposure += _deposit;

        positionId = nextPositionId++;
        positions[positionId] = Position({
            trader: agent.owner,
            agentId: _agentId,
            marketId: _marketId,
            deposit: _deposit,
            commitment:_commitment,
            revealed:false,
            direction: false,
            status: PositionStatus.ACTIVE,
            payout: 0
        });

        marketPositionIds[_marketId].push(positionId);
        userPositionIds[agent.owner].push(positionId);
        agentPositionIds[_agentId].push(positionId);

        market.totalDeposits += _deposit;
        market.totalPositions++;

        emit PositionSubmitted(positionId, _marketId, agent.owner, _agentId, _deposit);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Position Cancellation
    // ═══════════════════════════════════════════════════════════════════

    function cancelPosition(uint256 _positionId) external nonReentrant {
        Position storage pos = positions[_positionId];
        if (pos.trader == address(0)) revert PositionNotFound();
        if (pos.status != PositionStatus.ACTIVE) revert PositionNotActive();

        // Auth: owner of position, or if agent position, owner/delegate of agent
        if (pos.agentId == 0) {
            if (pos.trader != msg.sender) revert NotPositionOwner();
        } else {
            AgentConfig storage agent = agents[pos.agentId];
            if (msg.sender != agent.owner && msg.sender != agent.delegate) revert AgentNotAuthorized();
        }

        Market storage market = markets[pos.marketId];
        if (market.status != MarketStatus.OPEN) revert MarketNotOpen();

        pos.status = PositionStatus.CANCELLED;
        market.totalDeposits -= pos.deposit;
        market.totalPositions--;

        _removeFromArray(marketPositionIds[pos.marketId], _positionId);

        // Refund: back to agent vault or user wallet
        if (pos.agentId > 0) {
            AgentConfig storage agent = agents[pos.agentId];
            agent.balance += pos.deposit;
            if (agent.currentExposure >= pos.deposit) {
                agent.currentExposure -= pos.deposit;
            }
        } else {
            usdc.safeTransfer(msg.sender, pos.deposit);
        }

        emit PositionCancelled(_positionId, msg.sender, pos.deposit);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Market Resolution
    // ═══════════════════════════════════════════════════════════════════

   function resolveMarket(
    uint256 _marketId,
    bool _outcome
) external nonReentrant {   // ← payable hata diya (BNB pe nahi chahiye)
    Market storage market = markets[_marketId];
    if (market.creator == address(0)) revert MarketNotFound();
    if (market.creator != msg.sender) revert NotMarketCreator();
    if (market.status != MarketStatus.OPEN) revert MarketNotOpen();
    if (block.timestamp < market.resolutionTime) revert ResolutionTooEarly();

    uint256[] storage posIds = marketPositionIds[_marketId];
    uint256 posCount = posIds.length;

    if (posCount == 0) {
        market.status = MarketStatus.SETTLED;
        market.outcome = _outcome;
        emit MarketSettled(_marketId, _outcome, 0, 0, 0);
        return;
    }

    market.status = MarketStatus.RESOLVING;
    market.outcome = _outcome;

    uint256 yesPool = 0;
    uint256 noPool = 0;

    // Sab positions reveal hue hain ya nahi check karo
    for (uint256 i = 0; i < posCount; i++) {
        Position storage pos = positions[posIds[i]];
        if (!pos.revealed) {
            // optional: unrevealed positions ko forfeit/refund kar sakte ho
            // abhi simple: ignore kar rahe hain (ya revert kar do)
        }
        if (pos.revealed) {
            if (pos.direction) yesPool += pos.deposit;
            else noPool += pos.deposit;
        }
    }

    market.yesPool = yesPool;
    market.noPool = noPool;

    uint256 totalPool = yesPool + noPool;
    uint256 winningPool = _outcome ? yesPool : noPool;

    // Payouts distribute karo
    for (uint256 i = 0; i < posCount; i++) {
        Position storage pos = positions[posIds[i]];
        if (!pos.revealed) {
            pos.payout = 0;           // unrevealed = zero payout
            continue;
        }

        pos.status = PositionStatus.SETTLED;

        if (winningPool == 0) {
            pos.payout = pos.deposit;
        } else if (pos.direction == _outcome) {
            pos.payout = (pos.deposit * totalPool) / winningPool;
        } else {
            pos.payout = 0;
        }

        // Agent ya user ko payout
        if (pos.payout > 0) {
            if (pos.agentId > 0) {
                agents[pos.agentId].balance += pos.payout;
            } else {
                usdc.safeTransfer(pos.trader, pos.payout);
            }
        }
    }

    market.status = MarketStatus.SETTLED;
    emit MarketSettled(_marketId, _outcome, yesPool, noPool, posCount);
}

    // ═══════════════════════════════════════════════════════════════════
    // BITE v2 Callback
    // ═══════════════════════════════════════════════════════════════════

    // function onDecrypt(
    //     bytes[] calldata decryptedArguments,
    //     bytes[] calldata plaintextArguments
    // ) external override nonReentrant {
    //     uint256 marketId = abi.decode(plaintextArguments[0], (uint256));
    //     bool outcome = abi.decode(plaintextArguments[1], (bool));

    //     Market storage market = markets[marketId];
    //     uint256[] storage posIds = marketPositionIds[marketId];
    //     uint256 posCount = posIds.length;

    //     uint256 yesPool = 0;
    //     uint256 noPool = 0;

    //     // Phase 1: Decode all directions and sum pools
    //     for (uint256 i = 0; i < posCount; i++) {
    //         Position storage pos = positions[posIds[i]];
    //         bool direction = abi.decode(decryptedArguments[i], (bool));
    //         pos.direction = direction;

    //         if (direction) {
    //             yesPool += pos.deposit;
    //         } else {
    //             noPool += pos.deposit;
    //         }
    //     }

    //     market.yesPool = yesPool;
    //     market.noPool = noPool;

    //     uint256 totalPool = yesPool + noPool;
    //     uint256 winningPool = outcome ? yesPool : noPool;

    //     // Phase 2: Calculate and distribute payouts
    //     for (uint256 i = 0; i < posCount; i++) {
    //         Position storage pos = positions[posIds[i]];
    //         pos.status = PositionStatus.SETTLED;

    //         if (winningPool == 0) {
    //             pos.payout = pos.deposit;
    //         } else if (pos.direction == outcome) {
    //             pos.payout = (pos.deposit * totalPool) / winningPool;
    //         } else {
    //             pos.payout = 0;
    //         }

    //         // Route payout: to agent vault or directly to user
    //         if (pos.payout > 0) {
    //             if (pos.agentId > 0) {
    //                 agents[pos.agentId].balance += pos.payout;
    //             } else {
    //                 usdc.safeTransfer(pos.trader, pos.payout);
    //             }
    //         }

    //         // Update agent exposure
    //         if (pos.agentId > 0) {
    //             AgentConfig storage agent = agents[pos.agentId];
    //             if (agent.currentExposure >= pos.deposit) {
    //                 agent.currentExposure -= pos.deposit;
    //             }
    //         }

    //         emit PositionSettled(
    //             posIds[i], marketId, pos.trader,
    //             pos.direction, pos.deposit, pos.payout
    //         );
    //     }

    //     market.status = MarketStatus.SETTLED;
    //     emit MarketSettled(marketId, outcome, yesPool, noPool, posCount);
    // }

    // ═══════════════════════════════════════════════════════════════════
    // Refund (expired, unresolved)
    // ═══════════════════════════════════════════════════════════════════

    function claimRefund(uint256 _marketId) external nonReentrant {
        Market storage market = markets[_marketId];
        if (market.creator == address(0)) revert MarketNotFound();
        if (market.status != MarketStatus.OPEN) revert MarketNotOpen();
        if (block.timestamp < market.resolutionTime + REFUND_GRACE_PERIOD) revert RefundTooEarly();

        market.status = MarketStatus.CANCELLED;

        uint256[] storage posIds = marketPositionIds[_marketId];
        uint256 totalRefunded = 0;

        for (uint256 i = 0; i < posIds.length; i++) {
            Position storage pos = positions[posIds[i]];
            if (pos.status == PositionStatus.ACTIVE) {
                pos.status = PositionStatus.REFUNDED;
                pos.payout = pos.deposit;

                if (pos.agentId > 0) {
                    AgentConfig storage agent = agents[pos.agentId];
                    agent.balance += pos.deposit;
                    if (agent.currentExposure >= pos.deposit) {
                        agent.currentExposure -= pos.deposit;
                    }
                } else {
                    usdc.safeTransfer(pos.trader, pos.deposit);
                }

                totalRefunded += pos.deposit;
            }
        }

        emit MarketRefunded(_marketId, totalRefunded);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Multi-Agent Management
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Create a new agent with full config in one transaction.
     *         Payable: sends msg.value (sFUEL) to delegate for gas.
     */
    function createAgent(
        string calldata _name,
        string calldata _systemPrompt,
        uint8 _personality,
        address _delegate,
        uint256 _maxBetPerMarket,
        uint256 _maxTotalExposure,
        uint8 _allowedAssetTypes,
        uint8 _confidenceThreshold,
        bool _autoExecute
    ) external payable returns (uint256 agentId) {
        if (ownerAgentIds[msg.sender].length >= MAX_AGENTS_PER_USER) revert AgentLimitReached();

        agentId = nextAgentId++;
        agents[agentId] = AgentConfig({
            owner: msg.sender,
            delegate: _delegate,
            name: _name,
            systemPrompt: _systemPrompt,
            personality: _personality,
            balance: 0,
            maxBetPerMarket: _maxBetPerMarket,
            maxTotalExposure: _maxTotalExposure,
            currentExposure: 0,
            allowedAssetTypes: _allowedAssetTypes,
            confidenceThreshold: _confidenceThreshold,
            autoExecute: _autoExecute,
            isActive: true
        });

        ownerAgentIds[msg.sender].push(agentId);

        if (_delegate != address(0)) {
            delegateToAgentId[_delegate] = agentId;

            // Forward sFUEL to delegate for gas
            if (msg.value > 0) {
                payable(_delegate).sendValue(msg.value);
            }
        }

        emit AgentCreated(agentId, msg.sender, _delegate, _name, _personality);
    }

    /**
     * @notice Fund an agent's USDC vault. Requires prior USDC approval.
     */
    function fundAgent(uint256 _agentId, uint256 _amount) external nonReentrant {
        AgentConfig storage agent = agents[_agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert AgentNotAuthorized();
        if (_amount == 0) revert InvalidDeposit();

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        agent.balance += _amount;

        emit AgentFunded(_agentId, _amount, agent.balance);
    }

    /**
     * @notice Withdraw USDC from an agent's vault back to the owner.
     */
    function withdrawFromAgent(uint256 _agentId, uint256 _amount) external nonReentrant {
        AgentConfig storage agent = agents[_agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert AgentNotAuthorized();
        if (agent.balance < _amount) revert InsufficientWithdrawBalance();

        agent.balance -= _amount;
        usdc.safeTransfer(msg.sender, _amount);

        emit AgentWithdrawal(_agentId, _amount, agent.balance);
    }

    /**
     * @notice Update agent configuration. Only the owner can update.
     */
    function updateAgent(
        uint256 _agentId,
        string calldata _name,
        string calldata _systemPrompt,
        uint8 _personality,
        address _delegate,
        uint256 _maxBetPerMarket,
        uint256 _maxTotalExposure,
        uint8 _allowedAssetTypes,
        uint8 _confidenceThreshold,
        bool _autoExecute
    ) external {
        AgentConfig storage agent = agents[_agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert AgentNotAuthorized();

        // Clear old delegate mapping if changing
        if (agent.delegate != address(0) && agent.delegate != _delegate) {
            delete delegateToAgentId[agent.delegate];
        }

        agent.name = _name;
        agent.systemPrompt = _systemPrompt;
        agent.personality = _personality;
        agent.delegate = _delegate;
        agent.maxBetPerMarket = _maxBetPerMarket;
        agent.maxTotalExposure = _maxTotalExposure;
        agent.allowedAssetTypes = _allowedAssetTypes;
        agent.confidenceThreshold = _confidenceThreshold;
        agent.autoExecute = _autoExecute;

        if (_delegate != address(0)) {
            delegateToAgentId[_delegate] = _agentId;
        }

        emit AgentUpdated(_agentId, msg.sender);
    }

    function deactivateAgent(uint256 _agentId) external {
        AgentConfig storage agent = agents[_agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert AgentNotAuthorized();
        agent.isActive = false;
        emit AgentDeactivated(_agentId);
    }

    function activateAgent(uint256 _agentId) external {
        AgentConfig storage agent = agents[_agentId];
        if (agent.owner == address(0)) revert AgentNotFound();
        if (agent.owner != msg.sender) revert AgentNotAuthorized();
        agent.isActive = true;
        emit AgentActivated(_agentId);
    }

    // ═══════════════════════════════════════════════════════════════════
    // View Functions
    // ═══════════════════════════════════════════════════════════════════

    function getMarket(uint256 _marketId) external view returns (Market memory) {
        return markets[_marketId];
    }

    function getPosition(uint256 _positionId) external view returns (Position memory) {
        return positions[_positionId];
    }

    function getMarketPositionIds(uint256 _marketId) external view returns (uint256[] memory) {
        return marketPositionIds[_marketId];
    }

    function getUserPositionIds(address _user) external view returns (uint256[] memory) {
        return userPositionIds[_user];
    }

    function getMarketCount() external view returns (uint256) {
        return nextMarketId;
    }

    function getAgent(uint256 _agentId) external view returns (AgentConfig memory) {
        return agents[_agentId];
    }

    function getOwnerAgentIds(address _owner) external view returns (uint256[] memory) {
        return ownerAgentIds[_owner];
    }

    function getAgentPositionIds(uint256 _agentId) external view returns (uint256[] memory) {
        return agentPositionIds[_agentId];
    }

    function getAgentCount() external view returns (uint256) {
        return nextAgentId;
    }

    // ─── Internal Helpers ────────────────────────────────────────────

    function _removeFromArray(uint256[] storage arr, uint256 value) internal {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == value) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    // Allow contract to receive ETH for CTX gas
    receive() external payable {}
    fallback() external payable {}
}
