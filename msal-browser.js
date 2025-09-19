/*! @azure/msal-browser v2.38.1 2023-08-23 */
'use strict';
(function (global, factory) {
    typeof exports === 'object' && typeof module !== 'undefined' ? factory(exports) :
    typeof define === 'function' && define.amd ? define(['exports'], factory) :
    (global = typeof globalThis !== 'undefined' ? globalThis : global || self, factory(global.msal = {}));
})(this, (function (exports) { 'use strict';

    /*! *****************************************************************************
    Copyright (c) Microsoft Corporation.

    Permission to use, copy, modify, and/or distribute this software for any
    purpose with or without fee is hereby granted.

    THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
    REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
    AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
    INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
    LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
    OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
    PERFORMANCE OF THIS SOFTWARE.
    ***************************************************************************** */

    var __assign = function() {
        __assign = Object.assign || function __assign(t) {
            for (var s, i = 1, n = arguments.length; i < n; i++) {
                s = arguments[i];
                for (var p in s) if (Object.prototype.hasOwnProperty.call(s, p)) t[p] = s[p];
            }
            return t;
        };
        return __assign.apply(this, arguments);
    };

    function __awaiter(thisArg, _arguments, P, generator) {
        function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
        return new (P || (P = Promise))(function (resolve, reject) {
            function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
            function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
            function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
            step((generator = generator.apply(thisArg, _arguments || [])).next());
        });
    }

    function __generator(thisArg, body) {
        var _ = { label: 0, sent: function() { if (t[0] & 1) throw t[1]; return t[1]; }, trys: [], ops: [] }, f, y, t, g;
        return g = { next: verb(0), "throw": verb(1), "return": verb(2) }, typeof Symbol === "function" && (g[Symbol.iterator] = function() { return this; }), g;
        function verb(n) { return function (v) { return step([n, v]); }; }
        function step(op) {
            if (f) throw new TypeError("Generator is already executing.");
            while (_) try {
                if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
                if (y = 0, t) op = [op[0] & 2, t.value];
                switch (op[0]) {
                    case 0: case 1: t = op; break;
                    case 4: _.label++; return { value: op[1], done: false };
                    case 5: _.label++; y = op[1]; op = [0]; continue;
                    case 7: op = _.ops.pop(); _.trys.pop(); continue;
                    default:
                        if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
                        if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
                        if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
                        if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
                        if (t[2]) _.ops.pop();
                        _.trys.pop(); continue;
                }
                op = body.call(thisArg, _);
            } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
            if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
        }
    }

    function __spreadArray(to, from, pack) {
        if (pack || arguments.length === 2) for (var i = 0, l = from.length, ar; i < l; i++) {
            if (ar || !(i in from)) {
                if (!ar) ar = Array.prototype.slice.call(from, 0, i);
                ar[i] = from[i];
            }
        }
        return to.concat(ar || Array.prototype.slice.call(from));
    }

    /**
     * AuthErrorMessage class containing string constants used by error codes and messages.
     */
    var AuthErrorMessage = {
        unexpectedError: {
            code: "unexpected_error",
            desc: "Unexpected error in authentication."
        },
        createPostRequestFailed: {
            code: "post_request_failed",
            desc: "POST request failed."
        },
        createGetRequestFailed: {
            code: "get_request_failed",
            desc: "GET request failed."
        },
        invalidJsonError: {
            code: "invalid_json_error",
            desc: "The JSON value received from the server was not a valid JSON object."
        },
        serverUnavailable: {
            code: "server_unavailable",
            desc: "Server is temporarily unavailable."
        },
        unknownServerError: {
            code: "unknown_server_error",
            desc: "Unknown server error."
        },
        // This is a special error that requires three values: "code", "desc" and "suberror"
        endpointResolutionError: {
            code: "endpoint_resolution_error",
            desc: "Error: could not resolve endpoints. Please check network and try again."
        },
        networkError: {
            code: "network_error",
            desc: "Network request failed. Please check network connectivity and try again."
        },
        hashNotDeserialized: {
            code: "hash_not_deserialized",
            desc: "The hash value has not been deserialized."
        },
        blankEnvironmentStringError: {
            code: "blank_env_string_error",
            desc: "Given environment string was empty or null."
        },
        emptyAuthorityAliasError: {
            code: "empty_authority_alias_error",
            desc: "Authority alias is empty."
        },
        hashEmptyError: {
            code: "hash_empty_error",
            desc: "Hash value cannot be processed because it is empty."
        },
        urlEmptyError: {
            code: "url_empty_error",
            desc: "URL is empty."
        },
        urlInvalidError: {
            code: "url_invalid_error",
            desc: "URL is not valid."
        },
        authorityUriInvalidError: {
            code: "authority_uri_invalid_error",
            desc: "Authority URI is not valid."
        },
        protocolMismatchError: {
            code: "protocol_mismatch_error",
            desc: "Redirect URI protocol does not match request protocol."
        },
        authorityNotInTrustedList: {
            code: "authority_not_in_trusted_list",
            desc: "Authority is not in trusted list of authorities."
        },
        b2cAuthorityNotTrusted: {
            code: "b2c_authority_not_in_trusted_list",
            desc: "B2C authority is not in trusted list of authorities."
        },
        adfsAuthorityNotTrusted: {
            code: "adfs_authority_not_in_trusted_list",
            desc: "ADFS authority is not in trusted list of authorities."
        },
        ciamedAuthorityNotTrusted: {
            code: "ciamed_authority_not_in_trusted_list",
            desc: "CIAM authority is not in trusted list of authorities."
        },
        noLogoutEndpoint: {
            code: "no_logout_endpoint",
            desc: "Logout endpoint could not be found in the config."
        },
        noTokensFoundError: {
            code: "no_tokens_found",
            desc: "No tokens were found for the given scopes, and no authorization code was passed to acquireTokenByCode."
        },
        multipleMatchingTokens: {
            code: "multiple_matching_tokens",
            desc: "Multiple matching tokens found in cache. Please specify account."
        },
        multipleMatchingAccounts: {
            code: "multiple_matching_accounts",
            desc: "Multiple matching accounts found in cache."
        },
        tokenRequestCannotBeMade: {
            code: "request_cannot_be_made",
            desc: "Token request cannot be made without login."
        },
        appendEmptyScopeError: {
            code: "empty_scope_error",
            desc: "Cannot append empty scope to scope set. Please check logic."
        },
        removeEmptyScopeError: {
            code: "empty_scope_error",
            desc: "Cannot remove empty scope from scope set. Please check logic."
        },
        appendScopeSetError: {
            code: "cannot_append_scopeset",
            desc: "Cannot append scope set. Please check logic."
        },
        emptyInputScopeSetError: {
            code: "empty_input_scopeset",
            desc: "Empty input scope set cannot be processed."
        },
        deviceCodeUnsupportedError: {
            code: "device_code_unsupported",
            desc: "Device code flow is not supported by this authentication library."
        },
        invalidIdToken: {
            code: "invalid_id_token",
            desc: "Invalid ID token format."
        },
        noAccountError: {
            code: "no_account_found",
            desc: "No account object provided to the acquireTokenSilent API."
        },
        noAccountInSilentRequest: {
            code: "no_account_in_silent_request",
            desc: "Please pass an account object, silent flow is not supported without an account."
        },
        invalidCacheRecord: {
            code: "invalid_cache_record",
            desc: "Invalid cache record format."
        },
        cachePluginError: {
            code: "cache_plugin_error",
            desc: "A Cache Plugin was not initialized correctly, please check the documentation for specific instructions."
        },
        noCryptoObj: {
            code: "no_crypto_object",
            desc: "No crypto object created."
        },
        invalidStateError: {
            code: "invalid_state_error",
            desc: "State was not the expected format. Please check the logs for more details."
        },
        nonExistentStateError: {
            code: "nonexistent_state_error",
            desc: "State not found. Redirect request may have been aborted. For more information, please visit: aka.ms/msaljs/browser-errors."
        },
        stateMismatchError: {
            code: "state_mismatch_error",
            desc: "State mismatch error. Please check your network. Continued requests may cause cache overflow."
        },
        nonceMismatchError: {
            code: "nonce_mismatch_error",
            desc: "Nonce mismatch error. This may be caused by a race condition in asynchronous acquireToken calls. For more information, please visit: aka.ms/msaljs/browser-errors."
        },
        clientIdSingleScopeError: {
            code: "client_id_single_scope_error",
            desc: "Client ID can only be provided as a single scope."
        },
        tokenClaimsRequired: {
            code: "token_claims_required",
            desc: "Token claims are not populated. Cannot renew token."
        },
        popTokenNotGenerated: {
            code: "pop_token_not_generated",
            desc: "PoP token could not be generated. PoP tokens are not supported in this environment."
        },
        userTimeoutError: {
            code: "user_timeout_error",
            desc: "User login timed out."
        },
        clientInfoDecodingError: {
            code: "client_info_decoding_error",
            desc: "The client info could not be parsed/decoded correctly. Please check the logs for more details."
        },
        clientInfoNotPopulatedError: {
            code: "client_info_not_populated_error",
            desc: "The client info was not populated."
        },
        unableToGetClientInfoError: {
            code: "unable_to_get_client_info_error",
            desc: "Unable to get client info from native broker."
        },
        pkceNotGenerated: {
            code: "pkce_not_generated",
            desc: "The PKCE code challenge and verifier could not be generated."
        },
        cryptoDoesNotExist: {
            code: "crypto_nonexistent",
            desc: "The crypto object or function is not available."
        },
        invalidCacheType: {
            code: "invalid_cache_type",
            desc: "Invalid cache type"
        },
        unexpectedAccountType: {
            code: "unexpected_account_type",
            desc: "Unexpected account type."
        },
        accountNotSupported: {
            code: "account_not_supported",
            desc: "Account not supported"
        },
        noAccountFound: {
            code: "no_account_found",
            desc: "No account found in cache for given key."
        },
        noGuidGenerated: {
            code: "no_guid_generated",
            desc: "A Guid could not be successfully generated."
        },
        uninitializedPublicClientApplication: {
            code: "uninitialized_public_client_application",
            desc: "PublicClientApplication instance has not been initialized. Please call initialize() before using this API."
        },
        notImplemented: {
            code: "not_implemented",
            desc: "Not implemented."
        },
        claimsRequestParsingError: {
            code: "claims_request_parsing_error",
            desc: "Could not parse claims request."
        },
        invalidClaimsRequest: {
            code: "invalid_claims_request",
            desc: "The claims request provided is invalid."
        },
         Loopback Bypassed: {
            code: "loopback_bypassed",
            desc: "The loopback request was not fulfilled, another request took precedence."
        }
    };
    // This file is generated by the build process. See DEVELOPMENT.md for more details.
    var name = "@azure/msal-common";
    var version = "14.4.0";

    // This file is generated by the build process. See DEVELOPMENT.md for more details.
    var name$1 = "@azure/msal-browser";
    var version$1 = "2.38.1";

    /**
     * Browser specific error message constants
     */
    var BrowserAuthErrorMessage = {
        redirectUrisNotSet: {
            code: "redirect_uri_not_set",
            desc: "The redirectUri has not been set for this request. Please set it on the request object, or in the application config."
        },
        postLogoutUrisNotSet: {
            code: "post_logout_uri_not_set",
            desc: "The postLogoutRedirectUri has not been set for this request. Please set it on the request object, or in the application config."
        },
        navigateToLoginRequestUrlError: {
            code: "navigate_url_error",
            desc: "The navigateToLoginRequestUrl config property must be a function which returns a boolean."
        },
        noRedirectCallbacksSet: {
            code: "no_redirect_callbacks",
            desc: "No redirect callbacks have been set. Please call handleRedirectPromise() with the appropriate callbacks. It is recommended to call handleRedirectPromise() as early as possible in the application lifecycle."
        },
        hashDoesNotContainStateError: {
            code: "no_state_in_hash",
            desc: "Hash does not contain state. It is recommended to call handleRedirectPromise() as early as possible in the application lifecycle."
        },
        hashDoesNotContainKnownPropertiesError: {
            code: "hash_does_not_contain_known_properties",
            desc: "Hash does not contain any of the known properties. It is recommended to call handleRedirectPromise() as early as possible in the application lifecycle."
        },
        hashDoesNotContainNonceError: {
            code: "no_nonce_in_hash",
            desc: "Hash does not contain nonce. It is recommended to call handleRedirectPromise() as early as possible in the application lifecycle."
        },
        unsupportedBrowserError: {
            code: "unsupported_browser",
            desc: "The browser is not supported."
        },
        noNetworkConnectivity: {
            code: "no_network_connectivity",
            desc: "No network connectivity. Check your internet connection."
        },
        userCancelledError: {
            code: "user_cancelled",
            desc: "User cancelled the flow."
        },
        prohibitedProperty: {
            code: "prohibited_property_in_request",
            desc: "The request object contained a prohibited property. Please remove it and try again."
        },
        pkceNotGenerated: {
            code: "pkce_not_created",
            desc: "The PKCE code challenge and verifier could not be generated."
        },
        cryptoDoesNotExist: {
            code: "crypto_nonexistent",
            desc: "The crypto object or function is not available."
        },
        iframeError: {
            code: "iframe_error",
            desc: "Error occurred in the iframe."
        },
        interactionInProgress: {
            code: "interaction_in_progress",
            desc: "Interaction is currently in progress. Please ensure that this interaction has been completed before calling an interactive API. For more visit: aka.ms/msaljs/browser-errors."
        },
        noInteractionInProgress: {
            code: "no_interaction_in_progress",
            desc: "No interaction is currently in progress. Please ensure that an interactive request has been initiated."
        },
        popUpWindowError: {
            code: "popup_window_error",
            desc: "Error opening popup window. This can happen if you are using IE or if popups are blocked in the browser. For more visit: aka.ms/msaljs/browser-errors."
        },
        emptyWindowError: {
            code: "empty_window_error",
            desc: "window.open returned null or undefined. If you are using IE, please add the redirectUri to your trusted sites list. For more visit: aka.ms/msaljs/browser-errors."
        },
        monitorPopupTimeoutError: {
            code: "monitor_popup_timeout",
            desc: "Token request timed out. This may be caused by the user closing the popup window, a page navigation, or a memory leak in the application."
        },
        monitorIframeTimeoutError: {
            code: "monitor_iframe_timeout",
            desc: "Token request timed out. This may be caused by a page navigation, a memory leak in the application, or a third party script causing an infinite loop."
        },
        redirectInIframeError: {
            code: "redirect_in_iframe",
            desc: "Redirects are not supported for iframed applications. Please ensure you are using MSAL callbacks properly."
        },
        blockTokenRequestsInHiddenIframeError: {
            code: "block_hidden_iframe",
            desc: "Token requests are blocked in hidden iframes. This typically occurs when calling acquireTokenSilent from a hidden iframe. See the following for more details: https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-browser/docs/acquire-token-silent.md#using-acquiretokensilent-in-iframes"
        },
        blockAcquireTokenInPopupsError: {
            code: "block_popups",
            desc: "acquireToken APIs are not supported in popup windows. Please ensure you are not using MSAL in a popup."
        },
        tokenRequestCannotBeMadeInIframe: {
            code: "iframe_token_request
