// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {SelfVerificationRoot} from "../abstract/SelfVerificationRoot.sol";
import {ISelfVerificationRoot} from "../interfaces/ISelfVerificationRoot.sol";
import {IIdentityVerificationHubV1} from "../interfaces/IIdentityVerificationHubV1.sol";
import {IVcAndDiscloseCircuitVerifier} from "../interfaces/IVcAndDiscloseCircuitVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CircuitConstants} from "../constants/CircuitConstants.sol";

/**
 * @title Airdrop (Experimental)
 * @notice This contract manages an airdrop campaign by verifying user registrations with zero‐knowledge proofs
 *         and distributing ERC20 tokens. It is provided for testing and demonstration purposes only.
 *         **WARNING:** This contract has not been audited and is NOT intended for production use.
 * @dev Inherits from PassportAirdropRoot for registration logic and Ownable for administrative control.
 */
contract Airdrop is SelfVerificationRoot, Ownable {
    using SafeERC20 for IERC20;

    // ====================================================
    // Storage Variables
    // ====================================================

    /// @notice ERC20 token to be airdropped.
    IERC20 public immutable token;
    /// @notice Merkle root used to validate airdrop claims.
    bytes32 public merkleRoot;
    /// @notice Tracks addresses that have claimed tokens.
    mapping(address => bool) public claimed;
    /// @notice Indicates whether the registration phase is active.
    bool public isRegistrationOpen;
    /// @notice Indicates whether the claim phase is active.
    bool public isClaimOpen;

    mapping(uint256 => uint256) internal _nullifiers;
    mapping(uint256 => bool) internal _registeredUserIdentifiers;

    // ====================================================
    // Errors
    // ====================================================

    /// @notice Reverts when an invalid Merkle proof is provided.
    error InvalidProof();
    /// @notice Reverts when a user attempts to claim tokens more than once.
    error AlreadyClaimed();
    /// @notice Reverts when an unregistered address attempts to claim tokens.
    error NotRegistered(address nonRegisteredAddress);
    /// @notice Reverts when registration is attempted while the registration phase is closed.
    error RegistrationNotOpen();
    /// @notice Reverts when a claim attempt is made while registration is still open.
    error RegistrationNotClosed();
    /// @notice Reverts when a claim is attempted while claiming is not enabled.
    error ClaimNotOpen();

    error RegisteredNullifier();
    error InvalidUserIdentifier();

    // ====================================================
    // Events
    // ====================================================

    /// @notice Emitted when a user successfully claims tokens.
    /// @param index The index of the claim in the Merkle tree.
    /// @param account The address that claimed tokens.
    /// @param amount The amount of tokens claimed.
    event Claimed(uint256 index, address account, uint256 amount);
    /// @notice Emitted when the registration phase is opened.
    event RegistrationOpen();
    /// @notice Emitted when the registration phase is closed.
    event RegistrationClose();
    /// @notice Emitted when the claim phase is opened.
    event ClaimOpen();
    /// @notice Emitted when the claim phase is closed.
    event ClaimClose();

    event UserIdentifierRegistered(uint256 indexed registeredUserIdentifier, uint256 indexed nullifier);

    // ====================================================
    // Constructor
    // ====================================================

    /**
     * @notice Constructor for the experimental Airdrop contract.
     * @dev Initializes the airdrop parameters, zero-knowledge verification configuration,
     *      and sets the ERC20 token to be distributed.
     * @param _identityVerificationHub The address of the Identity Verification Hub.
     * @param _scope The expected proof scope for user registration.
     * @param _attestationId The expected attestation identifier required in proofs.
     * @param _token The address of the ERC20 token for airdrop.
     * @param _olderThanEnabled Flag indicating if 'olderThan' verification is enabled.
     * @param _olderThan Value for 'olderThan' verification.
     * @param _forbiddenCountriesEnabled Flag indicating if forbidden countries verification is enabled.
     * @param _forbiddenCountriesListPacked Packed list of forbidden countries.
     * @param _ofacEnabled Array of flags indicating which OFAC checks are enabled. [passportNo, nameAndDob, nameAndYob]
     */
    constructor(
        address _identityVerificationHub, 
        uint256 _scope, 
        uint256 _attestationId,
        address _token,
        bool _olderThanEnabled,
        uint256 _olderThan,
        bool _forbiddenCountriesEnabled,
        uint256[4] memory _forbiddenCountriesListPacked,
        bool[3] memory _ofacEnabled
    ) 
        SelfVerificationRoot(
            _identityVerificationHub, 
            _scope, 
            _attestationId, 
            _olderThanEnabled,
            _olderThan,
            _forbiddenCountriesEnabled,
            _forbiddenCountriesListPacked,
            _ofacEnabled
        )
        Ownable(_msgSender())
    {
        token = IERC20(_token);
    }  

    // ====================================================
    // External/Public Functions
    // ====================================================

    /**
     * @notice Sets the Merkle root for claim validation.
     * @dev Only callable by the contract owner.
     * @param _merkleRoot The new Merkle root.
     */
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
    }

    /**
     * @notice Updates the verification configuration for address registration.
     * @dev Only callable by the contract owner.
     * @param newVerificationConfig The new verification configuration.
     */
    function setVerificationConfig(
        ISelfVerificationRoot.VerificationConfig memory newVerificationConfig
    ) external onlyOwner {
        _verificationConfig = newVerificationConfig;
    }

    /**
     * @notice Opens the registration phase for users.
     * @dev Only callable by the contract owner.
     */
    function openRegistration() external onlyOwner {
        isRegistrationOpen = true;
        emit RegistrationOpen();    
    }

    /**
     * @notice Closes the registration phase.
     * @dev Only callable by the contract owner.
     */
    function closeRegistration() external onlyOwner {
        isRegistrationOpen = false;
        emit RegistrationClose();
    }

    /**
     * @notice Opens the claim phase, allowing registered users to claim tokens.
     * @dev Only callable by the contract owner.
     */
    function openClaim() external onlyOwner {
        isClaimOpen = true;
        emit ClaimOpen();
    }

    /**
     * @notice Closes the claim phase.
     * @dev Only callable by the contract owner.
     */
    function closeClaim() external onlyOwner {
        isClaimOpen = false;
        emit ClaimClose();
    }

    /**
     * @notice Registers a user's address by verifying a provided zero-knowledge proof.
     * @dev Reverts if the registration phase is not open.
     * @param proof The VC and Disclose proof data used to verify and register the user.
     */
    function verifySelfProof(
        IVcAndDiscloseCircuitVerifier.VcAndDiscloseProof memory proof
    ) 
        public 
        override 
    {

        if (!isRegistrationOpen) {
            revert RegistrationNotOpen();
        }
        
        if (_scope != proof.pubSignals[CircuitConstants.VC_AND_DISCLOSE_SCOPE_INDEX]) {
            revert InvalidScope();
        }

        if (_attestationId != proof.pubSignals[CircuitConstants.VC_AND_DISCLOSE_ATTESTATION_ID_INDEX]) {
            revert InvalidAttestationId();
        }

        if (_nullifiers[proof.pubSignals[CircuitConstants.VC_AND_DISCLOSE_NULLIFIER_INDEX]] != 0) {
            revert RegisteredNullifier();
        }
        
        if (proof.pubSignals[CircuitConstants.VC_AND_DISCLOSE_USER_IDENTIFIER_INDEX] == 0) {
            revert InvalidUserIdentifier();
        }

        IIdentityVerificationHubV1.VcAndDiscloseVerificationResult memory result = _identityVerificationHub.verifyVcAndDisclose(
            IIdentityVerificationHubV1.VcAndDiscloseHubProof({
                olderThanEnabled: _verificationConfig.olderThanEnabled,
                olderThan: _verificationConfig.olderThan,
                forbiddenCountriesEnabled: _verificationConfig.forbiddenCountriesEnabled,
                forbiddenCountriesListPacked: _verificationConfig.forbiddenCountriesListPacked,
                ofacEnabled: _verificationConfig.ofacEnabled,
                vcAndDiscloseProof: proof
            })
        );

        _nullifiers[result.nullifier] = proof.pubSignals[CircuitConstants.VC_AND_DISCLOSE_USER_IDENTIFIER_INDEX];
        _registeredUserIdentifiers[proof.pubSignals[CircuitConstants.VC_AND_DISCLOSE_USER_IDENTIFIER_INDEX]] = true;

        emit UserIdentifierRegistered(proof.pubSignals[CircuitConstants.VC_AND_DISCLOSE_USER_IDENTIFIER_INDEX], result.nullifier);
    }

    /**
     * @notice Retrieves the expected proof scope.
     * @return The scope value used for registration verification.
     */
    function getScope() external view returns (uint256) {
        return _scope;
    }

    /**
     * @notice Retrieves the expected attestation identifier.
     * @return The attestation identifier.
     */
    function getAttestationId() external view returns (uint256) {
        return _attestationId;
    }

    /**
     * @notice Retrieves the stored nullifier for a given key.
     * @param nullifier The nullifier to query.
     * @return The user identifier associated with the nullifier.
     */
    function getNullifier(uint256 nullifier) external view returns (uint256) {
        return _nullifiers[nullifier];
    }

    /**
     * @notice Retrieves the current verification configuration.
     * @return The verification configuration used for registration.
     */
    function getVerificationConfig() external view returns (ISelfVerificationRoot.VerificationConfig memory) {
        return _verificationConfig;
    }

    /**
     * @notice Checks if a given address is registered.
     * @param registeredAddress The address to check.
     * @return True if the address is registered, false otherwise.
     */
    function isRegistered(address registeredAddress) external view returns (bool) {
        return _registeredUserIdentifiers[uint256(uint160(registeredAddress))];
    }

    /**
     * @notice Allows a registered user to claim their tokens.
     * @dev Reverts if registration is still open, if claiming is disabled, if already claimed,
     *      or if the sender is not registered. Also validates the claim using a Merkle proof.
     * @param index The index of the claim in the Merkle tree.
     * @param amount The amount of tokens to be claimed.
     * @param merkleProof The Merkle proof verifying the claim.
     */
    function claim(
        uint256 index,
        uint256 amount,
        bytes32[] memory merkleProof
    ) external {
        if (isRegistrationOpen) {
            revert RegistrationNotClosed();
        }
        if (!isClaimOpen) {
            revert ClaimNotOpen();
        }
        if (claimed[msg.sender]) {
            revert AlreadyClaimed();
        }
        if (!_registeredUserIdentifiers[uint256(uint160(msg.sender))]) {
            revert NotRegistered(msg.sender);
        }

        // Verify the Merkle proof.
        bytes32 node = keccak256(abi.encodePacked(index, msg.sender, amount));
        if (!MerkleProof.verify(merkleProof, merkleRoot, node)) revert InvalidProof();

        // Mark as claimed and transfer tokens.
        _setClaimed();
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Claimed(index, msg.sender, amount);
    }

    // ====================================================
    // Internal Functions
    // ====================================================

    /**
     * @notice Internal function to mark the caller as having claimed their tokens.
     * @dev Updates the claimed mapping.
     */
    function _setClaimed() internal {
        claimed[msg.sender] = true;
    }
}
