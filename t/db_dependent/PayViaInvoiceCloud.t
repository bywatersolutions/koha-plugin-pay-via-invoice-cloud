#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 12;
use Test::Exception;

use File::Slurp qw( read_file );

use Koha::Database;
use Koha::Encryption;

use t::lib::Mocks;

use Koha::Plugin::Com::ByWaterSolutions::PayViaInvoiceCloud;

my $schema = Koha::Database->new->schema;

my $PREFIX = $Koha::Plugin::Com::ByWaterSolutions::PayViaInvoiceCloud::ENCRYPTION_PREFIX;

t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );

# The plugin is instantiated once, outside any transaction, because install() issues a
# CREATE TABLE and DDL implicitly commits in MySQL, which would break the subtests' isolation.
my $plugin = Koha::Plugin::Com::ByWaterSolutions::PayViaInvoiceCloud->new( { enable_plugins => 1 } );

# Every subtest calls upgrade() directly. It can't be triggered the normal way here because
# $VERSION is the literal string '{VERSION}' until the kpz is built, so Koha's version
# comparison in Koha::Plugins::Base always decides this is a downgrade and skips the hook.

subtest 'upgrade() migrates a cleartext credential' => sub {
    plan tests => 5;
    $schema->storage->txn_begin;

    $plugin->store_data( { api_key => 'cleartext-key-12345' } );
    unlike( $plugin->retrieve_data('api_key'), qr/^\Q$PREFIX\E/, 'stored value starts out unencrypted' );

    is( $plugin->upgrade, 1, 'upgrade() returns 1' );

    my $stored = $plugin->retrieve_data('api_key');
    like( $stored, qr/^\Q$PREFIX\E/, 'stored value now carries the encryption prefix' );
    isnt( $stored, 'cleartext-key-12345', 'stored value is no longer the cleartext credential' );
    is( $plugin->_get_secret('api_key'), 'cleartext-key-12345', 'the original credential is recoverable' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() is idempotent' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->store_data( { api_key => 'cleartext-key-12345' } );
    $plugin->upgrade;
    my $after_first = $plugin->retrieve_data('api_key');

    is( $plugin->upgrade, 1, 'a second upgrade() returns 1' );
    is( $plugin->retrieve_data('api_key'), $after_first, 'the stored value is byte-identical, so it was not re-encrypted' );
    is( $plugin->_get_secret('api_key'), 'cleartext-key-12345', 'the credential still decrypts to the original' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() leaves an already-encrypted value alone' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    my $encrypted = $PREFIX . Koha::Encryption->new->encrypt_hex('already-encrypted');
    $plugin->store_data( { api_key => $encrypted } );

    is( $plugin->upgrade, 1, 'upgrade() returns 1' );
    is( $plugin->retrieve_data('api_key'), $encrypted, 'the stored value is untouched' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() handles an empty or absent credential' => sub {
    plan tests => 4;
    $schema->storage->txn_begin;

    $plugin->store_data( { api_key => undef } );
    is( $plugin->upgrade, 1, 'upgrade() returns 1 with no credential stored' );
    is( $plugin->retrieve_data('api_key'), undef, 'nothing was written' );

    $plugin->store_data( { api_key => q{} } );
    is( $plugin->upgrade, 1, 'upgrade() returns 1 with an empty credential' );
    is( $plugin->retrieve_data('api_key'), q{}, 'the empty value was left as-is, not encrypted' );

    $schema->storage->txn_rollback;
};

subtest 'upgrade() is a no-op without an encryption key' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'encryption_key', q{} );

    $plugin->store_data( { api_key => 'cleartext-key-12345' } );

    my $returned;
    lives_ok { $returned = $plugin->upgrade } 'upgrade() does not die, so the plugin cannot vanish from the plugin list';
    is( $returned, 1, 'upgrade() still returns 1, so Koha will not retry it forever' );
    is( $plugin->retrieve_data('api_key'), 'cleartext-key-12345', 'the credential is left in cleartext and still usable' );

    t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );

    $schema->storage->txn_rollback;
};

subtest 'migration runs later once an encryption key is configured' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'encryption_key', q{} );
    $plugin->store_data( { api_key => 'cleartext-key-12345' } );
    $plugin->upgrade;
    is( $plugin->retrieve_data('api_key'), 'cleartext-key-12345', 'still cleartext while no key is set' );

    # The one-shot upgrade() hook will never fire again, so opening the configuration page
    # has to be able to finish the migration
    t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );
    $plugin->_encrypt_stored_credentials;

    like( $plugin->retrieve_data('api_key'), qr/^\Q$PREFIX\E/, 'encrypted once a key is available' );
    is( $plugin->_get_secret('api_key'), 'cleartext-key-12345', 'the credential is unchanged' );

    $schema->storage->txn_rollback;
};

subtest '_set_secret() and _get_secret() round-trip' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->_set_secret( 'api_key', 'a-brand-new-key' );

    my $stored = $plugin->retrieve_data('api_key');
    like( $stored, qr/^\Q$PREFIX\E/, 'the value was stored with the encryption prefix' );
    unlike( $stored, qr/a-brand-new-key/, 'the cleartext credential does not appear in the stored value' );
    is( $plugin->_get_secret('api_key'), 'a-brand-new-key', 'the credential round-trips' );

    $schema->storage->txn_rollback;
};

subtest '_get_secret() passes through unencrypted values' => sub {
    plan tests => 2;
    $schema->storage->txn_begin;

    $plugin->store_data( { api_key => 'legacy-cleartext' } );
    is( $plugin->_get_secret('api_key'), 'legacy-cleartext', 'an unprefixed value is returned as-is' );

    $plugin->store_data( { api_key => undef } );
    is( $plugin->_get_secret('api_key'), undef, 'a missing credential returns undef rather than dying' );

    $schema->storage->txn_rollback;
};

subtest '_get_secret() fails closed on an undecryptable value' => sub {
    plan tests => 1;
    $schema->storage->txn_begin;

    $plugin->store_data( { api_key => $PREFIX . 'deadbeefdeadbeef' } );

    throws_ok { $plugin->_get_secret('api_key') } qr/unable to decrypt/,
        'a corrupted credential dies instead of returning garbage to the payment processor';

    $schema->storage->txn_rollback;
};

subtest '_get_secret() fails closed when the encryption key becomes unavailable' => sub {
    plan tests => 1;
    $schema->storage->txn_begin;

    $plugin->_set_secret( 'api_key', 'a-brand-new-key' );
    t::lib::Mocks::mock_config( 'encryption_key', q{} );

    throws_ok { $plugin->_get_secret('api_key') } qr/encryption is unavailable/,
        'an encrypted credential dies when the key is gone, rather than being sent as ciphertext';

    t::lib::Mocks::mock_config( 'encryption_key', 'a test encryption passphrase' );

    $schema->storage->txn_rollback;
};

subtest 'non-ASCII credentials survive the round trip' => sub {
    plan tests => 1;
    $schema->storage->txn_begin;

    my $key = "clé-secrète-\x{263A}";
    $plugin->_set_secret( 'api_key', $key );
    is( $plugin->_get_secret('api_key'), $key, 'a UTF-8 credential round-trips unchanged' );

    $schema->storage->txn_rollback;
};

subtest 'a blank credential does not overwrite the stored one' => sub {
    plan tests => 3;
    $schema->storage->txn_begin;

    $plugin->_set_secret( 'api_key', 'the-real-key' );
    my $stored = $plugin->retrieve_data('api_key');

    $plugin->_set_secret( 'api_key', q{} );
    is( $plugin->retrieve_data('api_key'), $stored, 'an empty submitted value leaves the stored credential alone' );

    $plugin->_set_secret( 'api_key', undef );
    is( $plugin->retrieve_data('api_key'), $stored, 'an absent submitted value leaves the stored credential alone' );

    # Guards the round-trip bug: if the template ever renders the stored value back into the
    # form field again, saving would re-encrypt the ciphertext and destroy the credential
    my $template = read_file( $plugin->mbf_path('configure.tt') );
    unlike( $template, qr/name="api_key"[^>]*value="\[%\s*api_key/,
        'configure.tt never renders the stored credential back into the form field' );

    $schema->storage->txn_rollback;
};
