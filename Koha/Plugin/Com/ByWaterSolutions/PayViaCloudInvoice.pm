package Koha::Plugin::Com::ByWaterSolutions::PayViaCloudInvoice;

use Modern::Perl;

use HTTP::Request;
use JSON qw(from_json to_json);
use LWP::UserAgent;
use List::Util qw(sum);
use MIME::Base64 qw( encode_base64 );

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name        => 'Pay Via Cloud Invoice',
    author      => 'Kyle M Hall',
    description =>
      'This plugin enables online OPAC fee payments via Cloud Invoice',
    date_authored   => '2020-04-14',
    date_updated    => '1900-01-01',
    minimum_version => '19.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
};

our $ENABLE_DEBUGGING = 1;

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
      . "/cgi-bin/koha/opac-account-pay-return.pl?payment_method=Koha::Plugin::Com::ByWaterSolutions::PayViaCloudInvoice?token=$token";
    my $postback_url = C4::Context->preference('OPACBaseURL')
      . "/api/v1/contrib/cloudinvoice/handle_payment";

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
                        "TypeID"     => $self->retrieve_data('invoice_type_id'),
                        "BalanceDue" => $amount,
                        "CCServiceFee" => $self->retrieve_data('cc_service_fee'),
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

    my $post_url = "https://www.invoicecloud.com/cloudpaymentsapi/v2";
    my $api_key  = encode_base64( $self->retrieve_data('api_key') );

    my $req = HTTP::Request->new( 'POST', $post_url );
    $req->header( 'Content-Type'  => 'application/json' );
    $req->header( 'Authorization' => "Basic $api_key" );
    $req->content( to_json($data) );

    my $lwp      = LWP::UserAgent->new;
    my $response = $lwp->request($req);
    unless ( $response->is_success ) {
        warn "REQUEST: " . $req->as_string;
        warn "RESPONSE: " . $response->as_string;
        die "Failed to connect to Cloud Invoice! " . $response->status_line;
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

    my ( $template, $logged_in_borrowernumber ) = get_template_and_user(
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

    $template->param(
        borrower => scalar Koha::Patrons->find($logged_in_borrowernumber),
        token    => $token,
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

    return 'cloudinvoice';
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            api_key         => $self->retrieve_data('api_key'),
            invoice_type_id => $self->retrieve_data('invoice_type_id'),
            cc_service_fee  => $self->retrieve_data('cc_service_fee'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                api_key         => $cgi->param('api_key'),
                invoice_type_id => $cgi->param('invoice_type_id'),
                cc_service_fee  => $cgi->param('cc_service_fee'),
            }
        );
        $self->go_home();
    }
}

sub install() {
    my $dbh = C4::Context->dbh();

    my $query = q{
		CREATE TABLE IF NOT EXISTS cloud_invoice_plugin_tokens
		  (
			 token          VARCHAR(128),
			 created_on     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
			 borrowernumber INT(11) NOT NULL,
             accountline_ids TEXT NOT NULL,
			 PRIMARY KEY (token),
			 CONSTRAINT token_bn FOREIGN KEY (borrowernumber) REFERENCES borrowers (
			 borrowernumber ) ON DELETE CASCADE ON UPDATE CASCADE
		  )
		ENGINE=innodb
		DEFAULT charset=utf8mb4
		COLLATE=utf8mb4_unicode_ci;
    };

    return 1;
}

sub uninstall() {
    return 1;
}

1;
