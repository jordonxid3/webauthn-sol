// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Base64Url} from "FreshCryptoLib/utils/Base64Url.sol";
import {FCL_ecdsa} from "FreshCryptoLib/FCL_ecdsa.sol";
import {Test, console2} from "forge-std/Test.sol";

/// @title WebAuthn
/// @notice A library for verifying WebAuthn Authentication Assertions, built off the work
/// of Daimo. This library is optimized for calldata,
/// and attempts to use the RIP-7212 precompile for signature verification.
/// If precompile verification fails, it falls back to FreshCryptoLib.
/// @author Coinbase (https://github.com/base-org/webauthn-sol)
/// @author Daimo (https://github.com/daimo-eth/p256-verifier/blob/master/src/WebAuthn.sol)
library WebAuthn {
    struct WebAuthnAuth {
      bytes authenticatorData;
        bytes clientDataJSON;
        uint256 challengeIndex;
        uint256 typeIndex;
        /// @dev The r value of secp256r1 signature
        uint256 r;
        /// @dev The s value of secp256r1 signature
        uint256 s;
    }

    /// @dev Bit 0, User present bit in authenticatorData
    bytes1 constant AUTH_DATA_FLAGS_UP = 0x01;
    /// @dev Bit 2, User verified bit in authenticatorData
    bytes1 constant AUTH_DATA_FLAGS_UV = 0x04;
    /// @dev secp256r1 curve order / 2 for malleability check
    uint256 constant P256_N_DIV_2 = 57896044605178124381348723474703786764998477612067880171211129530534256022184;
    address constant VERIFIER = address(0x100);

    bytes32 constant EXPECTED_TYPE_HASH = keccak256('"type":"webauthn.get"');

    /**
     * @notice Verifies a Webauthn Authentication Assertion as described
     * in https://www.w3.org/TR/webauthn-3/#sctn-verifying-assertion.
     *
     * @dev We do not verify all the steps as described in the specification, only ones relevant
     * to our context. Please carefully read through this list before usage.
     * Specifically, we do verify the following:
     * - Verify that authenticatorData (which comes from the authenticator,
     *   such as iCloud Keychain) indicates a well-formed assertion with the user present bit set.
     *   If requireUserVerification is set, checks that the authenticator enforced
     *   user verification. User verification should be required if,
     *   and only if, options.userVerification is set to required in the request
     * - Verifies that the client JSON is of type "webauthn.get", i.e. the client
     *   was responding to a request to assert authentication.
     * - Verifies that the client JSON contains the requested challenge.
     * - Finally, verifies that (r, s) constitute a valid signature over both
     *   the authenicatorData and client JSON, for public key (x, y).
     *
     * We make some assumptions about the particular use case of this verifier,
     * so we do NOT verify the following:
     * - Does NOT verify that the origin in the clientDataJSON matches the
     *   Relying Party's origin: It is considered the authenticator's
     *   responsibility to ensure that the user is interacting with the correct
     *   RP. This is enforced by most high quality authenticators properly,
     *   particularly the iCloud Keychain and Google Password Manager were
     *   tested.
     * - Does NOT verify That c.topOrigin is well-formed: We assume c.topOrigin
     *   would never be present, i.e. the credentials are never used in a
     *   cross-origin/iframe context. The website/app set up should disallow
     *   cross-origin usage of the credentials. This is the default behaviour for
     *   created credentials in common settings.
     * - Does NOT verify that the rpIdHash in authData is the SHA-256 hash of an
     *   RP ID expected by the Relying Party: This means that we rely on the
     *   authenticator to properly enforce credentials to be used only by the
     *   correct RP. This is generally enforced with features like Apple App Site
     *   Association and Google Asset Links. To protect from edge cases in which
     *   a previously-linked RP ID is removed from the authorised RP IDs,
     *   we recommend that messages signed by the authenticator include some
     *   expiry mechanism.
     * - Does NOT verify the credential backup state: This assumes the credential
     *   backup state is NOT used as part of Relying Party business logic or
     *   policy.
     * - Does NOT verify the values of the client extension outputs: This assumes
     *   that the Relying Party does not use client extension outputs.
     * - Does NOT verify the signature counter: Signature counters are intended
     *   to enable risk scoring for the Relying Party. This assumes risk scoring
     *   is not used as part of Relying Party business logic or policy.
     * - Does NOT verify the attestation object: This assumes that
     *   response.attestationObject is NOT present in the response, i.e. the
     *   RP does not intend to verify an attestation.
     *
     * Our verification does not use full JSON parsing but leverages the serialization spec
     * https://www.w3.org/TR/webauthn/#clientdatajson-serialization
     * which is depended on by the limited verification algorithm
     * https://www.w3.org/TR/webauthn/#clientdatajson-verification.
     * We believe our templating approach is robust to future changes because the spec states
     * "...future versions of this specification must not remove any of the fields
     * type, challenge, origin, or crossOrigin from CollectedClientData.
     * They also must not change the serialization algorithm to change the order
     * in which those fields are serialized."
     * https://www.w3.org/TR/webauthn/#clientdatajson-development
     *
     * @param challenge The challenge that was provided by the relying party
     * @param requireUserVerification A boolean indicating whether user verification is required
     * @param webAuthnAuth The WebAuthnAuth struct containing the authenticatorData, origin, crossOriginAndRemainder, r, and s
     * @param x The x coordinate of the public key
     * @param y The y coordinate of the public key
     * @return A boolean indicating authentication assertion passed validation
     */
    function verify(
        bytes memory challenge,
        bool requireUserVerification,
        WebAuthnAuth memory webAuthnAuth,
        uint256 x,
        uint256 y
    ) internal view returns (bool) {
        if (webAuthnAuth.s > P256_N_DIV_2) {
            // guard against signature malleability
            return false;
        }

        bytes memory _type = _slice(webAuthnAuth.clientDataJSON, 1, 22);
        if (keccak256(_type) != EXPECTED_TYPE_HASH) {
            return false;
        }

        // 12. Verify that the value of C.challenge equals the base64url encoding of options.challenge.
        string memory challengeB64url = Base64Url.encode(challenge);
        // 13. Verify that the value of C.challenge equals the base64url encoding of options.challenge.
        bytes memory expectedChallenge = bytes(string.concat('"challenge":"', challengeB64url, '"'));
        bytes memory actualChallenge = _slice(webAuthnAuth.clientDataJSON, 23, 23 + expectedChallenge.length);
        if (keccak256(actualChallenge) != keccak256(expectedChallenge)) {
            return false;
        }
        
        // Skip 15., 16., and 16.

        // 17. Verify that the UP bit of the flags in authData is set.
        if (webAuthnAuth.authenticatorData[32] & AUTH_DATA_FLAGS_UP != AUTH_DATA_FLAGS_UP) {
            return false;
        }

        // 18. If user verification was determined to be required, verify that the UV bit of the flags in authData is set. Otherwise, ignore the value of the UV flag.
        if (requireUserVerification && (webAuthnAuth.authenticatorData[32] & AUTH_DATA_FLAGS_UV) != AUTH_DATA_FLAGS_UV)
        {
            return false;
        }

        // skip 19., 20., and 21.

        // 22. Let hash be the result of computing a hash over the cData using SHA-256.
        bytes32 clientDataJSONHash = sha256(bytes(webAuthnAuth.clientDataJSON));

        // 23. Using credentialPublicKey, verify that sig is a valid signature over the binary concatenation of authData and hash.
        bytes32 messageHash = sha256(abi.encodePacked(webAuthnAuth.authenticatorData, clientDataJSONHash));
        bytes memory args = abi.encode(messageHash, webAuthnAuth.r, webAuthnAuth.s, x, y);
        // try the RIP-7212 precompile address
        (bool success, bytes memory ret) = VERIFIER.staticcall(args);
        // staticcall will not revert if address has no code
        // check return length
        // note that even if precompile exists, ret.length is 0 when verification returns false
        // so an invalid signature will be checked twice: once by the precompile and once by FCL.
        // Ideally this signature failure is simulated offchain and no one actually pay this gas.
        bool valid = ret.length > 0;
        if (success && valid) return abi.decode(ret, (uint256)) == 1;

        return FCL_ecdsa.ecdsa_verify(messageHash, webAuthnAuth.r, webAuthnAuth.s, x, y);
    }

    function _slice(bytes memory data, uint256 start, uint256 end) internal pure returns (bytes memory) {
        bytes memory result = new bytes(end - start);
        assembly {
            let dataStart := add(data, 32) // Skip array length
            let resultStart := add(result, 32) // Skip array length

            for { let i := start } lt(i, end) { i := add(i, 1) } {
                let _byte := mload(add(dataStart, i))
                mstore(add(resultStart, sub(i, start)), _byte)
            }
        }
        return result;
    }
}
