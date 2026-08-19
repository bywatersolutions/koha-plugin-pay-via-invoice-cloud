package Koha::Plugin::Com::ByWaterSolutions::PayViaInvoiceCloud;

use Modern::Perl;

use Encode qw( decode_utf8 encode_utf8 );
use HTTP::Request;
use JSON qw(from_json to_json decode_json);
use LWP::UserAgent;
use List::Util qw(sum);
use MIME::Base64 qw( encode_base64 );
use Try::Tiny;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;
use Koha::DateUtils qw( dt_from_string output_pref );

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name        => 'Pay Via Invoice Cloud',
    author      => 'Kyle M Hall',
    description =>
      'This plugin enables online OPAC fee payments via Invoice Cloud',
    date_authored   => '2020-04-14',
    date_updated    => '1900-01-01',
    minimum_version => '19.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
};

our $ENABLE_DEBUGGING = 1;

# Encrypted credentials are stored with this marker in front of the ciphertext so we can
# tell them apart from cleartext values left behind by versions before encryption existed.
our $ENCRYPTION_PREFIX = 'koha-enc-v1:';

# The stored configuration keys holding secrets, which must be encrypted at rest
our @CREDENTIAL_KEYS = qw( api_key );

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

sub opac_online_payment {
    my ( $self, $args ) = @_;

    return 1;
}

sub opac_online_payment_begin {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $borrowernumber ) = C4::Auth::get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_begin.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my @accountline_ids = $cgi->multi_param('accountline');

    my $rs = Koha::Database->new()->schema()->resultset('Accountline');
    my @accountlines = map { $rs->find($_) } @accountline_ids;

    my $patron = scalar Koha::Patrons->find($borrowernumber);

    my $token = "B" . $borrowernumber . "T" . time;
    C4::Context->dbh->do(
        q{
        INSERT INTO cloud_invoice_plugin_tokens ( token, borrowernumber, accountline_ids )
        VALUES ( ?, ?, ? )
    }, undef, $token, $borrowernumber, join( ",", @accountline_ids )
    );

    my $amount =
      sprintf( "%.2f", sum( map { $_->amountoutstanding } @accountlines ) );

    my $return_url = C4::Context->preference('OPACBaseURL')
      . "/cgi-bin/koha/opac-account-pay-return.pl?payment_method=Koha::Plugin::Com::ByWaterSolutions::PayViaInvoiceCloud&token=$token";
    my $postback_url = C4::Context->preference('OPACBaseURL')
      . "/api/v1/contrib/invoicecloud/payment";

    my $data = {
        "CreateCustomerRecord" => JSON::true,
        "Customers"            => [
            {
                "AccountNumber" => $patron->id,
                "Name"          => $patron->firstname . ' ' . $patron->surname,
                "Address" => $patron->streetnumber . ' ' . $patron->address,
                ,
                "City"         => $patron->city,
                "State"        => $patron->state,
                "Zip"          => $patron->zipcode,
                "EmailAddress" => $patron->first_valid_email_address,
                ,
                "Invoices" => [
                    {
                        "InvoiceNumber" => $token,
                        "TypeID"        => $self->retrieve_data('invoice_type_id'),
                        "BalanceDue"    => $amount,
                        "CCServiceFee"  => $self->retrieve_data('cc_service_fee'),
                        "ACHServiceFee" => $self->retrieve_data('cc_service_fee'),
                        "DueDate"       => output_pref( { dt => dt_from_string, dateonly => 1 } ),
                        "InvoiceDate"   => output_pref( { dt => dt_from_string, dateonly => 1 } ),
                    }
                ]
            }
        ],
        "AllowSwipe"      => JSON::false,
        "AllowCCPayment"  => JSON::true,
        "AllowACHPayment" => JSON::false,
        "ReturnURL"       => $return_url,
        "PostBackURL"     => $postback_url,
        "BillerReference" => $patron->id,
        "ViewMode"        => 0,
    };
    warn "POST DATA: " . Data::Dumper::Dumper( $data );

    my $post_url = "https://www.invoicecloud.com/cloudpaymentsapi/v2";
    # _get_secret returns characters, and encode_base64 dies on anything non-ASCII
    my $api_key = encode_base64( encode_utf8( $self->_get_secret('api_key') ) );

    my $req = HTTP::Request->new( 'POST', $post_url );
    $req->header( 'Content-Type'  => 'application/json' );
    $req->header( 'Authorization' => "Basic $api_key" );
    $req->content( to_json($data) );

    my $lwp      = LWP::UserAgent->new;
    my $response = $lwp->request($req);
    unless ( $response->is_success ) {
        warn "REQUEST: " . $req->as_string;
        warn "RESPONSE: " . $response->as_string;
        die "Failed to connect to Invoice Cloud! " . $response->status_line;
    }
    my $message = from_json( $response->decoded_content );
    warn "RESPONSE MESSAGE: " . Data::Dumper::Dumper($message);
    my $cloud_payment_url = $message->{Data}->{CloudPaymentURL};

    $template->param(
        borrower          => $patron,
        cloud_payment_url => $cloud_payment_url,
        accountlines      => \@accountlines,
        payment_method    => scalar $cgi->param('payment_method'),
    );

    print $cgi->header();
    print $template->output();
}

sub opac_online_payment_end {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my ( $template, $logged_in_borrowernumber ) = C4::Auth::get_template_and_user(
        {
            template_name   => $self->mbf_path('opac_online_payment_end.tt'),
            query           => $cgi,
            type            => 'opac',
            authnotrequired => 0,
            is_plugin       => 1,
        }
    );

    my $token    = $cgi->param('token');
    my $dbh      = C4::Context->dbh;
    my $query    = "SELECT * FROM cloud_invoice_plugin_tokens WHERE token = ?";
    my $token_hr = $dbh->selectrow_hashref( $query, undef, $token );
    warn "TOKEN: " . Data::Dumper::Dumper( $token_hr );

    $template->param(
        borrower => scalar Koha::Patrons->find($logged_in_borrowernumber),
        token    => $token_hr,
    );

    print $cgi->header();
    print $template->output();
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'invoicecloud';
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    # An instance that had no encryption key when the plugin was upgraded still holds its
    # credentials in cleartext, so try again every time someone opens the configuration page
    $self->_encrypt_stored_credentials;

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        my $stored_api_key = $self->retrieve_data('api_key');

        ## Grab the values we already have for our settings, if any exist
        ## The API key itself is deliberately never sent to the template
        $template->param(
            api_key_is_set => ( defined $stored_api_key && length $stored_api_key ) ? 1 : 0,
            api_key_is_encrypted =>
                ( $stored_api_key && index( $stored_api_key, $ENCRYPTION_PREFIX ) == 0 ) ? 1 : 0,
            encryption_available => $self->_encryption ? 1 : 0,
            csrf_token           => $self->_csrf_token,
            invoice_type_id      => $self->retrieve_data('invoice_type_id'),
            cc_service_fee       => $self->retrieve_data('cc_service_fee'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        # An empty API key field means "keep the current key", so _set_secret ignores it
        $self->_set_secret( 'api_key', scalar $cgi->param('api_key') );

        $self->store_data(
            {
                invoice_type_id => $cgi->param('invoice_type_id'),
                cc_service_fee  => $cgi->param('cc_service_fee'),
            }
        );
        $self->go_home();
    }
}

=head3 _encryption

    my $encryption = $self->_encryption;

Returns a Koha::Encryption object, or undef when encryption is unavailable. It is unavailable
on Koha before 22.05, and on any instance where encryption_key is unset in koha-conf.xml.

=cut

sub _encryption {
    my ($self) = @_;

    return try {
        require Koha::Encryption;
        Koha::Encryption->new;
    } catch {
        undef;
    };
}

=head3 _csrf_token

    my $token = $self->_csrf_token;

Returns a CSRF token for the configuration form, or undef on Koha versions that have no
Koha::Token. Koha::Middleware::CSRF answers any tokenless POST to the staff interface with
a 403, so the configuration form cannot be submitted without this.

=cut

sub _csrf_token {
    my ($self) = @_;

    return try {
        require Koha::Token;
        Koha::Token->new->generate_csrf( { session_id => scalar $self->{'cgi'}->cookie('CGISESSID') } );
    } catch {
        undef;
    };
}

=head3 _get_secret

    my $api_key = $self->_get_secret('api_key');

Returns the cleartext value of a stored credential. Values stored before encryption was added
carry no prefix and are returned as-is, so an instance without an encryption key keeps working.

=cut

sub _get_secret {
    my ( $self, $key ) = @_;

    my $stored = $self->retrieve_data($key);
    return $stored unless defined $stored && length $stored;
    return $stored unless index( $stored, $ENCRYPTION_PREFIX ) == 0;

    my $ciphertext = substr( $stored, length $ENCRYPTION_PREFIX );

    my $encryption = $self->_encryption;
    die "Pay Via Invoice Cloud: '$key' is stored encrypted but Koha's encryption is unavailable."
        . " Set 'encryption_key' in koha-conf.xml.\n"
        unless $encryption;

    my $plaintext = try {
        decode_utf8( $encryption->decrypt_hex($ciphertext) );
    } catch {
        undef;
    };

    # Decrypting with the wrong key doesn't raise an error, it just yields an empty string,
    # so an empty result has to be treated as a failure rather than as an empty credential.
    die "Pay Via Invoice Cloud: unable to decrypt '$key'. The 'encryption_key' in koha-conf.xml"
        . " may have changed. Re-enter the credential in the plugin configuration.\n"
        unless defined $plaintext && length $plaintext;

    return $plaintext;
}

=head3 _set_secret

    $self->_set_secret( 'api_key', $value );

Stores a credential, encrypted when encryption is available. An empty value is ignored so that
saving the configuration form without retyping the credential keeps the stored one.

=cut

sub _set_secret {
    my ( $self, $key, $plaintext ) = @_;

    return unless defined $plaintext && length $plaintext;

    my $encryption = $self->_encryption;
    unless ($encryption) {
        warn "Pay Via Invoice Cloud: storing '$key' in cleartext because Koha's encryption is"
            . " unavailable. Set 'encryption_key' in koha-conf.xml.";
        $self->store_data( { $key => $plaintext } );
        return;
    }

    $self->store_data( { $key => $ENCRYPTION_PREFIX . $encryption->encrypt_hex( encode_utf8($plaintext) ) } );

    return;
}

=head3 _encrypt_stored_credentials

    $self->_encrypt_stored_credentials;

Encrypts any credential still held in cleartext. Safe to call repeatedly, and never dies: an
instance with no encryption key has to keep working on the cleartext credential it already has.

=cut

sub _encrypt_stored_credentials {
    my ($self) = @_;

    foreach my $key (@CREDENTIAL_KEYS) {
        my $stored = $self->retrieve_data($key);
        next unless defined $stored && length $stored;
        next if index( $stored, $ENCRYPTION_PREFIX ) == 0;

        my $encryption = $self->_encryption;
        unless ($encryption) {
            warn "Pay Via Invoice Cloud: cannot encrypt '$key' because Koha's encryption is"
                . " unavailable. Set 'encryption_key' in koha-conf.xml.";
            next;
        }

        $self->store_data( { $key => $ENCRYPTION_PREFIX . $encryption->encrypt_hex( encode_utf8($stored) ) } );
    }

    return 1;
}

=head3 upgrade

Encrypts credentials that earlier versions of this plugin stored in cleartext.

=cut

sub upgrade {
    my ( $self, $args ) = @_;

    $self->_encrypt_stored_credentials;

    return 1;
}

=head3 cronjob_nightly

Koha runs this nightly for every enabled plugin ( misc/cronjobs/plugins_nightly.pl,
invoked by the packages' daily cron ). Removes tokens from checkouts that were begun
but never completed. The rows are otherwise only removed when a payment finishes, so
abandoned checkouts accumulate forever.

A checkout completes within minutes, so a week old token is long abandoned. The window
is deliberately generous - deleting a token for a checkout still in flight would make
its payment unprocessable when the processor answers.

=cut

sub cronjob_nightly {
    my ($self) = @_;

    C4::Context->dbh->do(q{
        DELETE FROM cloud_invoice_plugin_tokens
        WHERE created_on < DATE_SUB(NOW(), INTERVAL 7 DAY)
    });

    return;
}

sub install {
    my ( $self, $args ) = @_;

    my $dbh = C4::Context->dbh();

    my $query = q{
		CREATE TABLE IF NOT EXISTS cloud_invoice_plugin_tokens
		  (
			 token          VARCHAR(128),
			 created_on     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			 borrowernumber INT(11) NOT NULL,
             accountline_ids TEXT NOT NULL,
			 PRIMARY KEY (token),
			 CONSTRAINT cloudinvoice_token_bn FOREIGN KEY (borrowernumber) REFERENCES borrowers (
			 borrowernumber ) ON DELETE CASCADE ON UPDATE CASCADE
		  )
		ENGINE=innodb
		DEFAULT charset=utf8mb4
		COLLATE=utf8mb4_unicode_ci;
    };

    $dbh->do($query);

    return 1;
}

sub uninstall() {
    return 1;
}

1;
