// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import '@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol';
import '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import '@openzeppelin/contracts/utils/Counters.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/utils/Context.sol';
import '@openzeppelin/contracts/utils/Timers.sol';
import '@openzeppelin/contracts/utils/math/SafeCast.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/governance/TimelockController.sol';

// BitDAO token contract interface.
interface IERC20Votes is IERC20 {
    function getCurrentVotes(address account) external returns (uint256);
}

// Governance contract.
contract Governance is Context, ERC165, EIP712 {
    using SafeCast for uint256;
    using Counters for Counters.Counter;
    using Timers for Timers.BlockNumber;

    bytes32 public constant BALLOT_TYPEHASH =
    keccak256('Ballot(uint256 proposalId,uint8 support)');
    bytes32 private constant _DELEGATION_TYPEHASH =
    keccak256('Delegation(address delegatee,uint256 nonce,uint256 expiry)');
    bytes32 private constant _UNDELEGATION_TYPEHASH =
    keccak256(
        'Undelegation(address delegatee,uint256 nonce,uint256 expiry)'
    );

    enum VoteType {
        Against,
        For,
        Slashing
    }

    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    /**
     * @dev Proposal structure.
     */
    struct Proposal {
        uint256 id;
        uint256 eta;
        uint256[] values;
        uint256[] forVotes;
        uint256[] againstVotes;
        uint256[] slashingVotes;
        bytes32[] roles;
        bytes32[] actions;
        bytes32 descriptionHash;
        Timers.BlockNumber voteStart;
        Timers.BlockNumber voteEnd;
        address[] targets;
        address proposer;
        bytes[] calldatas;
        string[] signatures;
        bool canceled;
        bool executed;
        mapping(address => Receipt) receipts;
    }

    /**
     * @dev Receipt structure.
     */
    struct Receipt {
        bool hasVoted;
        uint8 support;
        uint96[] votes;
    }

    IERC20Votes public token;
    TimelockController private _timelock;

    bytes32[] public rolesList;
    mapping(uint256 => bytes32) private _timelockIds;
    mapping(bytes32 => bool) private _roles;
    mapping(bytes32 => mapping(address => bool)) public votersRoles;
    mapping(address => mapping(bytes32 => mapping(address => uint256)))
    public delegations;
    mapping(address => mapping(bytes32 => uint256)) public delegatees;
    mapping(address => mapping(bytes32 => uint256)) public delegated;
    mapping(address => mapping(bytes32 => bytes32)) public actionsRoles;
    mapping(address => mapping(bytes32 => uint256)) public actionsQuorums;
    mapping(bytes32 => uint256) public proposalThresholds;
    mapping(bytes32 => address) public rolesChildrenDAO;

    mapping(uint256 => Proposal) private _proposals;
    mapping(address => uint256) private _nonces;

    event ProposalCreated(
        uint256 proposalId,
        address proposer,
        address[] targets,
        uint256[] values,
        bytes32[] roles,
        bytes[] calldatas,
        string[] signatures,
        bytes32[] actions,
        uint256 startBlock,
        uint256 endBlock,
        string description
    );
    event ProposalCanceled(uint256 proposalId);
    event ProposalExecuted(uint256 proposalId);
    event ProposalQueued(uint256 proposalId, uint256 eta);
    event TimelockChange(address oldTimelock, address newTimelock);
    event VoteCast(
        address indexed voter,
        uint256 proposalId,
        uint8 support,
        string reason
    );

    /**
     * @dev Restrict access to governor executing address. Some module might override the _executor function to make
     * sure this modifier is consistant with the execution model.
     */
    modifier onlyGovernance() {
        require(_msgSender() == _executor(), 'Governor: onlyGovernance');
        _;
    }

    modifier roleExists(bytes32 role) {
        require(_roles[role], 'Governance::roleExists: role does not exist');
        _;
    }

    modifier hasRole(bytes32 role, address delegatee) {
        require(
            votersRoles[role][delegatee],
            'Governance::hasRole: delegatee does not have the role'
        );
        _;
    }

    constructor(IERC20Votes token_) EIP712(name(), version()) {
        token = token_;
    }

    /**
     * @dev Address through which the governor executes action. Will be overloaded by module that execute actions
     * through another contract such as a timelock.
     */
    function _executor() internal view virtual returns (address) {
        return address(this);
    }

    /**
     * @dev Function to receive ETH that will be handled by the governor (disabled if executor is a third party contract)
     */
    receive() external payable virtual {
        require(_executor() == address(this));
    }

    function version() public pure virtual returns (string memory) {
        return '0.0.1';
    }

    function name() public pure virtual returns (string memory) {
        return 'BitDAO';
    }

    /**
     * @dev Public accessor to check the address of the timelock
     */
    function timelock() public view virtual returns (address) {
        return address(_timelock);
    }

    function votingDelay() public pure virtual returns (uint256) {
        return 1; // 1 block
    }

    function votingPeriod() public pure virtual returns (uint256) {
        return 17280; // ~3 days in blocks
    }

    /**
     * @dev Public endpoint to update the underlying timelock instance. Restricted to the timelock itself, so updates
     * must be proposed, scheduled and executed using the {Governor} workflow.
     */
    function updateTimelock(TimelockController newTimelock)
    external
    virtual
    onlyGovernance
    {
        _updateTimelock(newTimelock);
    }

    function _updateTimelock(TimelockController newTimelock) private {
        emit TimelockChange(address(_timelock), address(newTimelock));
        _timelock = newTimelock;
    }

    /**
     * @dev Public accessor to check the eta of a queued proposal
     */
    function proposalEta(uint256 proposalId)
    public
    view
    virtual
    returns (uint256)
    {
        uint256 eta = _timelock.getTimestamp(_timelockIds[proposalId]);
        return eta == 1 ? 0 : eta; // _DONE_TIMESTAMP (1) should be replaced with a 0 value
    }

    function hashProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public pure virtual returns (uint256) {
        return
        uint256(
            keccak256(
                abi.encode(targets, values, calldatas, descriptionHash)
            )
        );
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes32[] memory roles,
        string[] memory signatures,
        bytes[] memory calldatas,
        bytes32[] memory actions,
        string memory description
    ) public virtual returns (uint256) {
        for (uint256 i = 0; i < roles.length; ++i) {
            require(
                votersRoles[roles[i]][_msgSender()],
                'Governance::propose: Proposer must have proposal roles'
            );
        }
        require(
            targets.length == values.length,
            'Governance::propose: invalid proposal length'
        );
        require(
            targets.length == calldatas.length,
            'Governance::propose: invalid proposal length'
        );
        require(
            targets.length == actions.length,
            'Governance::propose: invalid proposal length'
        );
        require(targets.length > 0, 'Governance::propose: empty proposal');

        bytes32 descriptionHash = keccak256(bytes(description));
        uint256 proposalId = hashProposal(
            targets,
            values,
            _encodeCalldata(signatures, calldatas),
            descriptionHash
        );

        Proposal storage proposal = _proposals[proposalId];
        require(
            proposal.voteStart.isUnset(),
            'Governance::propose: proposal already exists'
        );
        require(
            proposal.descriptionHash == bytes32(0),
            'Governance::propose: proposal already exists'
        );

        proposal.proposer = _msgSender();
        proposal.targets = targets;
        proposal.values = values;
        proposal.roles = roles;
        proposal.calldatas = calldatas;
        proposal.signatures = signatures;
        proposal.actions = actions;
        proposal.descriptionHash = descriptionHash;

        uint64 snapshot = block.number.toUint64() + votingDelay().toUint64();
        uint64 deadline = snapshot + votingPeriod().toUint64();

        proposal.voteStart.setDeadline(snapshot);
        proposal.voteEnd.setDeadline(deadline);

        return proposalId;
    }

    function registerNewRole(bytes32 role) external onlyGovernance {
        _roles[role] = true;
        rolesList.push(role);
    }

    function registerNewAction(
        address target,
        bytes32 action,
        bytes32 role,
        uint256 quorum
    ) external roleExists(role) onlyGovernance {
        actionsRoles[target][action] = role;
        actionsQuorums[target][action] = quorum;
    }

    function addNewRoleMember(bytes32 role, address member)
    external
    roleExists(role)
    onlyGovernance
    {
        votersRoles[role][member] = true;
    }

    function setProposalThreshold(bytes32 role, uint256 threshold)
    external
    roleExists(role)
    onlyGovernance
    {
        proposalThresholds[role] = threshold;
    }

    function setVotes() external virtual {
        for (uint256 i = 0; i < rolesList.length; ++i) {
            delegatees[_msgSender()][rolesList[i]] = token.getCurrentVotes(
                _msgSender()
            );
        }
    }

    function delegate(
        bytes32 role,
        uint256 votes,
        address delegatee
    ) external virtual roleExists(role) hasRole(role, delegatee) {
        _delegate(role, votes, delegatee);
    }

    function delegateBySig(
        bytes32 role,
        uint256 votes,
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual roleExists(role) hasRole(role, delegatee) {
        require(
            block.timestamp <= expiry,
            'Governance::delegateBySig: signature expired'
        );
        address signer = ECDSA.recover(
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        _DELEGATION_TYPEHASH,
                        role,
                        delegatee,
                        nonce,
                        expiry
                    )
                )
            ),
            v,
            r,
            s
        );
        require(
            nonce == _nonces[signer]++,
            'Governance::delegateBySig: invalid nonce'
        );
        _delegate(role, votes, delegatee);
    }

    function undelegate(
        bytes32 role,
        uint256 votes,
        address delegatee
    ) external virtual roleExists(role) hasRole(role, delegatee) {
        _undelegate(role, votes, delegatee);
    }

    function undelegateBySig(
        bytes32 role,
        uint256 votes,
        address delegatee,
        uint256 nonce,
        uint256 expiry,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual roleExists(role) hasRole(role, delegatee) {
        require(
            block.timestamp <= expiry,
            'Governance::undelegateBySig: signature expired'
        );
        address signer = ECDSA.recover(
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        _UNDELEGATION_TYPEHASH,
                        role,
                        delegatee,
                        nonce,
                        expiry
                    )
                )
            ),
            v,
            r,
            s
        );
        require(
            nonce == _nonces[signer]++,
            'Governance::undelegateBySig: invalid nonce'
        );
        _undelegate(role, votes, delegatee);
    }

    function _delegate(
        bytes32 role,
        uint256 votes,
        address delegatee
    ) internal virtual {
        delegatees[_msgSender()][role] -= votes;
        delegations[_msgSender()][role][delegatee] += votes;
        delegatees[delegatee][role] += votes;
    }

    function _undelegate(
        bytes32 role,
        uint256 votes,
        address delegatee
    ) internal virtual {
        delegatees[delegatee][role] -= votes;
        delegations[_msgSender()][role][delegatee] -= votes;
        delegatees[_msgSender()][role] += votes;
    }

    function getVotes(address account, bytes32 role)
    public
    view
    virtual
    returns (uint256)
    {
        return delegatees[account][role];
    }

    /**
     * @dev See {IGovernorCompatibilityBravo-queue}.
     */
    function queue(uint256 proposalId) public virtual {
        Proposal storage proposal = _proposals[proposalId];
        queue(
            proposal.targets,
            proposal.values,
            _encodeCalldata(proposal.signatures, proposal.calldatas),
            proposal.descriptionHash
        );
    }

    /**
     * @dev Function to queue a proposal to the timelock.
     */
    function queue(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public virtual returns (uint256) {
        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            descriptionHash
        );

        require(
            state(proposalId) == ProposalState.Succeeded,
            'Governor: proposal not successful'
        );

        uint256 delay = _timelock.getMinDelay();
        _timelockIds[proposalId] = _timelock.hashOperationBatch(
            targets,
            values,
            calldatas,
            0,
            descriptionHash
        );
        _timelock.scheduleBatch(
            targets,
            values,
            calldatas,
            0,
            descriptionHash,
            delay
        );

        emit ProposalQueued(proposalId, block.timestamp + delay);

        return proposalId;
    }

    /**
     * @dev See {IGovernor-execute}.
     */
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable virtual returns (uint256) {
        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            descriptionHash
        );

        ProposalState status = state(proposalId);
        require(
            status == ProposalState.Succeeded || status == ProposalState.Queued,
            'Governor: proposal not successful'
        );
        _proposals[proposalId].executed = true;

        emit ProposalExecuted(proposalId);

        _execute(proposalId, targets, values, calldatas, descriptionHash);

        return proposalId;
    }

    /**
     * @dev Internal execution mechanism. Can be overriden to implement different execution mechanism
     */
    function _execute(
        uint256, /* proposalId */
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual {
        _timelock.executeBatch{value: msg.value}(
            targets,
            values,
            calldatas,
            0,
            descriptionHash
        );
    }

    /**
     * @dev See {IGovernorCompatibilityBravo-cancel}.
     */
    function cancel(uint256 proposalId) public virtual {
        Proposal storage proposal = _proposals[proposalId];

        require(
            _msgSender() == proposal.proposer,
            'Governance::cancel: sender must be the proposer'
        );
        for (uint256 i = 0; i < proposal.roles.length; ++i) {
            require(
                getVotes(proposal.proposer, proposal.roles[i]) <
                proposalThresholds[proposal.roles[i]],
                'Governance::cancel: proposer above threshold'
            );
        }

        _cancel(
            proposal.targets,
            proposal.values,
            _encodeCalldata(proposal.signatures, proposal.calldatas),
            proposal.descriptionHash
        );
    }

    /**
     * @dev Internal cancel mechanism: locks up the proposal timer, preventing it from being re-submitted. Marks it as
     * canceled to allow distinguishing it from executed proposals.
     *
     * Emits a {IGovernor-ProposalCanceled} event.
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal virtual returns (uint256) {
        uint256 proposalId = hashProposal(
            targets,
            values,
            calldatas,
            descriptionHash
        );
        ProposalState status = state(proposalId);

        require(
            status != ProposalState.Canceled &&
            status != ProposalState.Expired &&
            status != ProposalState.Executed,
            'Governance::_cancel: proposal not active'
        );
        _proposals[proposalId].canceled = true;

        emit ProposalCanceled(proposalId);

        if (_timelockIds[proposalId] != 0) {
            _timelock.cancel(_timelockIds[proposalId]);
            delete _timelockIds[proposalId];
        }

        return proposalId;
    }

    /**
     * @dev Encodes calldatas with optional function signature.
     */
    function _encodeCalldata(
        string[] memory signatures,
        bytes[] memory calldatas
    ) private pure returns (bytes[] memory) {
        bytes[] memory fullcalldatas = new bytes[](calldatas.length);

        for (uint256 i = 0; i < signatures.length; ++i) {
            fullcalldatas[i] = bytes(signatures[i]).length == 0
            ? calldatas[i]
            : abi.encodeWithSignature(signatures[i], calldatas[i]);
        }

        return fullcalldatas;
    }

    /**
     * @dev See {IGovernor-state}.
     */
    function state(uint256 proposalId)
    public
    view
    virtual
    returns (ProposalState)
    {
        Proposal storage proposal = _proposals[proposalId];

        if (proposal.executed) {
            return ProposalState.Executed;
        } else if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (proposal.voteStart.isPending()) {
            return ProposalState.Pending;
        } else if (proposal.voteEnd.isPending()) {
            return ProposalState.Active;
        } else if (proposal.voteEnd.isExpired()) {
            if (_quorumReached(proposalId) && _voteSucceeded(proposalId)) {
                bytes32 queueid = _timelockIds[proposalId];
                if (queueid == bytes32(0)) {
                    return ProposalState.Succeeded;
                } else if (_timelock.isOperationDone(queueid)) {
                    return ProposalState.Executed;
                } else {
                    return ProposalState.Queued;
                }
            } else {
                return ProposalState.Defeated;
            }
        } else {
            revert('Governance::state: unknown proposal id');
        }
    }

    /**
     * @dev See {IGovernor-proposalSnapshot}.
     */
    function proposalSnapshot(uint256 proposalId)
    public
    view
    virtual
    returns (uint256)
    {
        return _proposals[proposalId].voteStart.getDeadline();
    }

    /**
     * @dev See {IGovernor-proposalDeadline}.
     */
    function proposalDeadline(uint256 proposalId)
    public
    view
    virtual
    returns (uint256)
    {
        return _proposals[proposalId].voteEnd.getDeadline();
    }

    /**
     * @dev See {IGovernorCompatibilityBravo-proposals}.
     */
    function proposals(uint256 proposalId)
    public
    view
    virtual
    returns (
        uint256 id,
        address proposer,
        uint256 eta,
        uint256 startBlock,
        uint256 endBlock,
        uint256[] memory forVotes,
        uint256[] memory againstVotes,
        uint256[] memory slashingVotes,
        bool canceled,
        bool executed
    )
    {
        id = proposalId;
        eta = proposalEta(proposalId);
        startBlock = proposalSnapshot(proposalId);
        endBlock = proposalDeadline(proposalId);

        Proposal storage proposal = _proposals[proposalId];
        proposer = proposal.proposer;
        forVotes = proposal.forVotes;
        againstVotes = proposal.againstVotes;
        slashingVotes = proposal.slashingVotes;

        ProposalState status = state(proposalId);
        canceled = status == ProposalState.Canceled;
        executed = status == ProposalState.Executed;
    }

    /**
     * @dev See {IGovernorCompatibilityBravo-getActions}.
     */
    function getActions(uint256 proposalId)
    public
    view
    virtual
    returns (
        address[] memory targets,
        uint256[] memory values,
        bytes32[] memory roles,
        string[] memory signatures,
        bytes[] memory calldatas,
        bytes32[] memory actions
    )
    {
        Proposal storage proposal = _proposals[proposalId];
        return (
        proposal.targets,
        proposal.values,
        proposal.roles,
        proposal.signatures,
        proposal.calldatas,
        proposal.actions
        );
    }

    /**
     * @dev See {IGovernorCompatibilityBravo-getReceipt}.
     */
    function getReceipt(uint256 proposalId, address voter)
    public
    view
    virtual
    returns (Receipt memory)
    {
        return _proposals[proposalId].receipts[voter];
    }

    // ==================================================== Voting ====================================================

    function hasVoted(uint256 proposalId, address account)
    public
    view
    virtual
    returns (bool)
    {
        return _proposals[proposalId].receipts[account].hasVoted;
    }

    function _quorumReached(uint256 proposalId)
    internal
    view
    virtual
    returns (bool)
    {
        Proposal storage proposal = _proposals[proposalId];
        bool reached = true;
        for (uint256 i = 0; i < proposal.actions.length; ++i) {
            if (
                actionsQuorums[proposal.targets[i]][proposal.actions[i]] >
                proposal.forVotes[i]
            ) {
                reached = false;
            }
        }
        return reached;
    }

    function _voteSucceeded(uint256 proposalId)
    internal
    view
    virtual
    returns (bool)
    {
        Proposal storage proposal = _proposals[proposalId];
        bool allFor = true;
        for (uint256 i = 0; i < proposal.roles.length; ++i) {
            if (
                proposal.forVotes[i] <= proposal.againstVotes[i] ||
                proposal.forVotes[i] <= proposal.slashingVotes[i]
            ) {
                allFor = false;
            }
        }
        return allFor;
    }

    /**
     * @dev See {IGovernor-castVote}.
     */
    function castVote(uint256 proposalId, uint8 support) public virtual {
        address voter = _msgSender();
        _castVote(proposalId, voter, support, '');
    }

    /**
     * @dev See {IGovernor-castVoteWithReason}.
     */
    function castVoteWithReason(
        uint256 proposalId,
        uint8 support,
        string calldata reason
    ) public virtual {
        address voter = _msgSender();
        _castVote(proposalId, voter, support, reason);
    }

    /**
     * @dev See {IGovernor-castVoteBySig}.
     */
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        address voter = ECDSA.recover(
            _hashTypedDataV4(
                keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support))
            ),
            v,
            r,
            s
        );
        _castVote(proposalId, voter, support, '');
    }

    /**
     * @dev Internal vote casting mechanism: Check that the vote is pending, that it has not been cast yet, retrieve
     * voting weight using {IGovernor-getVotes} and call the {_countVote} internal function.
     *
     * Emits a {IGovernor-VoteCast} event.
     */
    function _castVote(
        uint256 proposalId,
        address account,
        uint8 support,
        string memory reason
    ) internal virtual {
        require(
            state(proposalId) == ProposalState.Active,
            'Governor::_castVote: vote not currently active'
        );

        _countVote(proposalId, account, support);

        emit VoteCast(account, proposalId, support, reason);
    }

    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support
    ) internal virtual {
        Proposal storage proposal = _proposals[proposalId];
        Receipt storage receipt = proposal.receipts[account];

        require(!receipt.hasVoted, 'Governance::_countVote: vote already cast');
        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = new uint96[](proposal.roles.length);

        for (uint256 i = 0; i < proposal.roles.length; ++i) {
            if (votersRoles[proposal.roles[i]][account]) {
                uint256 weight = getVotes(account, proposal.roles[i]);
                receipt.votes[i] = SafeCast.toUint96(weight);
                if (support == uint8(VoteType.Against)) {
                    proposal.againstVotes[i] += weight;
                } else if (support == uint8(VoteType.For)) {
                    proposal.forVotes[i] += weight;
                } else if (support == uint8(VoteType.Slashing)) {
                    proposal.slashingVotes[i] += weight;
                } else {
                    revert('Governance::_countVote: invalid vote type');
                }
            }
        }
    }
}