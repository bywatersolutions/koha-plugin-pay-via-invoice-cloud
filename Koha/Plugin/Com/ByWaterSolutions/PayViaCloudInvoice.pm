package Koha::Plugin::Com::ByWaterSolutions::PayViaCloudInvoice;

use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use Koha::Account;
use Koha::Account::Lines;
use List::Util qw(sum);

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name          => 'Pay Via Cloud Invoice',
    author        => 'Kyle M Hall',
    description   => 'This plugin enables online OPAC fee payments via Cloud Invoice',
    date_authored => '2020-04-14',
    date_updated  => '1900-01-01',
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

    my ( $template, $borrowernumber ) = get_template_and_user(
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
    }, undef, $token, $borrowernumber, join(",", @accountline_ids )
    );

    my $amount = sprintf("%.2f", sum( map { $_->amountoutstanding } @accountlines ) );

    my $return_url = C4::Context->preference('OPACBaseURL') . "/cgi-bin/koha/opac-account-pay-return.pl?payment_method=Koha::Plugin::Com::ByWaterSolutions::PayViaCloudInvoice?token=$token";
    my $postback_url = C4::Context->preference('OPACBaseURL') . "/api/v1/???????";

    my $url_params = [
        {
            key => 'biller_guid',
            val => $self->retrieve_data('biller_guid')
        },    # BillerGUID issued for specifc Biller
        {
            key => 'invoice_number',
            val => $token
        },
        {
            key => 'balance_due',
            val => $amount
        },
        {
            key => 'invoice_type_id',
            val => $self->retrieve_data('invoice_type_id')
        },    # InvoiceTypeId, must be enabled for Biller
        {
            key => 'customer_name',
            val => $patron->firstname . $patron->surname
        },
        {
            key => 'customer_address',
            val => $patron->streetnumber . ' ' . $patron->address
        },
        {
            key => 'customer_city',
            val => $patron->city
        },
        {
            key => 'customer_state',
            val => $patron->state
        },
        {
            key => 'customer_zip',
            val => $patron->zipcode
        },
        {
            key => 'customer_email_address',
            val => $patron->first_valid_email_address
        },
        {
            key => 'biller_reference',
            val => $patron->id
        },
        {
            key => 'return_url',
            val => $return_url
        },
        {
            key => 'postback_url',
            val => $postback_url
        },
    ];

    $template->param(
        borrower             => $patron,
        url_params           => $url_params,
        payment_method       => scalar $cgi->param('payment_method'),
        accountlines         => \@accountlines,
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
            biller_guid     => $self->retrieve_data('biller_guid'),
            invoice_type_id => $self->retrieve_data('invoice_type_id'),
        );

        print $cgi->header();
        print $template->output();
    }
    else {
        $self->store_data(
            {
                biller_guid     => $cgi->param('biller_guid'),
                invoice_type_id => $cgi->param('invoice_type_id'),
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
