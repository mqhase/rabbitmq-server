#!/usr/bin/env bash

SCRIPT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

TEST_CASES_PATH=/oauth/with-sp-initiated
TEST_CONFIG_PATH=/oauth
PROFILES="forward-proxy keycloak forward-proxy-oauth-provider keycloak-mgt-oauth-provider tls"

source $SCRIPT/../../bin/suite_template $@
runWith keycloak forward-proxy
