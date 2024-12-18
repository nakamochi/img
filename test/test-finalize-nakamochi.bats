#!/usr/bin/env bats
# shellcheck disable=SC2016

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

# shellcheck source=/dev/null
source tools/finalize-nakamochi.sh

# we run twice, first one new template config, then on already patched config,
# to check that both ways work
bitcoind_rpcauth_1='rpcauth=rpc:186ae69296424a04ef496a3c4ded94ce$fd4d109a3b370422afa1b0dfce8470c6b6f1167a3591ddc7d069b7970393683e'
bitcoind_rpcuser_1='rpc'
bitcoind_rpcpass_1='eQFPcf_0HD7zpAiFQqD3EPmIdqW9GE0tC74QBVAIjmw='
bitcoind_onion_1='bvqxwmku42oyrktpdiz3irakwyzyni77dcgbxrvynxb3f4vukfa2mryd.onion'
lnd_onion_1='lyau5bjibj5t246i6o2ieotcv62weylb3wpjmivvfiihyrywsrnevyyd.onion'
bitcoind_rpcauth_2='rpcauth=rpc:6893139467e3a9d61485c7b2bfaaf47a$9d09029bceef774b761e984dff70bbb3c23a4baeb4b0d86c93b381c097c476d2'
bitcoind_rpcuser_2='rpc'
bitcoind_rpcpass_2='ILXudrSSgVV7bmxGoO9H7prg9YXEd2e3mZoolTW-oOQ='
bitcoind_onion_2='bhyhhvggguv2iprx23ryev3tsy2vcvlx43qfdes3zpbth464nl6mecad.onion'
lnd_onion_2='l4jmbelb62qfwfmqequ2xyltjxyv3cc2wdjsvsst3p57c2fw3y2ojpqd.onion'

setup()
{
    tempdir="$(mktemp -d)"
    export tempdir
}

@test "Test patching bitcoind configuration" {
    cp ./rootfiles/home/bitcoind/mainnet.conf "$tempdir/mainnet.conf"

    patch_bitcoind_conf "$tempdir/mainnet.conf" "$bitcoind_rpcauth_1" "$bitcoind_rpcpass_1" "$bitcoind_onion_1"
    run bats_pipe grep -A 1 "rpcauth.py rpc" "$tempdir/mainnet.conf" \| tail -n 1
    assert_output "# $bitcoind_rpcpass_1"
    run grep "^rpcauth=" "$tempdir/mainnet.conf"
    assert_output "$bitcoind_rpcauth_1"
    run grep "^externalip=" "$tempdir/mainnet.conf"
    assert_output "externalip=$bitcoind_onion_1"

    patch_bitcoind_conf "$tempdir/mainnet.conf" "$bitcoind_rpcauth_2" "$bitcoind_rpcpass_2" "$bitcoind_onion_2"
    run bats_pipe grep -A 1 "rpcauth.py rpc" "$tempdir/mainnet.conf" \| tail -n 1
    assert_output "# $bitcoind_rpcpass_2"
    run grep "^rpcauth=" "$tempdir/mainnet.conf"
    assert_output "$bitcoind_rpcauth_2"
    run grep "^externalip=" "$tempdir/mainnet.conf"
    assert_output "externalip=$bitcoind_onion_2"
}

@test "Test patching lnd configuration" {
    cp ./rootfiles/home/lnd/lnd.mainnet.conf "$tempdir/lnd.mainnet.conf"

    patch_lnd_conf "$tempdir/lnd.mainnet.conf" "$bitcoind_rpcuser_1" "$bitcoind_rpcpass_1" "$lnd_onion_1"
    run grep "^tlsextradomain=" "$tempdir/lnd.mainnet.conf"
    assert_output "tlsextradomain=$lnd_onion_1"
    run grep "^externalhosts=" "$tempdir/lnd.mainnet.conf"
    assert_output "externalhosts=$lnd_onion_1"
    run grep "^bitcoind.rpcuser=" "$tempdir/lnd.mainnet.conf"
    assert_output "bitcoind.rpcuser=$bitcoind_rpcuser_1"
    run grep "^bitcoind.rpcpass=" "$tempdir/lnd.mainnet.conf"
    assert_output "bitcoind.rpcpass=$bitcoind_rpcpass_1"

    patch_lnd_conf "$tempdir/lnd.mainnet.conf" "$bitcoind_rpcuser_2" "$bitcoind_rpcpass_2" "$lnd_onion_2"
    run grep "^tlsextradomain=" "$tempdir/lnd.mainnet.conf"
    assert_output "tlsextradomain=$lnd_onion_2"
    run grep "^externalhosts=" "$tempdir/lnd.mainnet.conf"
    assert_output "externalhosts=$lnd_onion_2"
    run grep "^bitcoind.rpcuser=" "$tempdir/lnd.mainnet.conf"
    assert_output "bitcoind.rpcuser=$bitcoind_rpcuser_2"
    run grep "^bitcoind.rpcpass=" "$tempdir/lnd.mainnet.conf"
    assert_output "bitcoind.rpcpass=$bitcoind_rpcpass_2"
}

@test "Test script run" {
    temp_usd="$(mktemp -d)"
    temp_ssd="$(mktemp -d)"
    cp -r ./rootfiles/* "$temp_usd/"
    mkdir -p "$temp_ssd/bitcoind/mainnet/blocks"
    NOSUDOTESTMODE=1 ./tools/finalize-nakamochi.sh - - "$temp_usd" "$temp_ssd"
    # TODO: regexp checks
    #run grep "^tlsextradomain=" "$temp_usd/home/lnd/lnd.mainnet.conf"
    #assert_output "tlsextradomain=.*\.onion"
    rm -rf "$temp_usd"
    rm -rf "$temp_ssd"
}

teardown()
{
    rm -rf "$tempdir"
}
