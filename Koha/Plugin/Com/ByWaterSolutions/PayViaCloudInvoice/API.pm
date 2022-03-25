package Koha::Plugin::Com::ByWaterSolutions::PayViaCloudInvoice::API;

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use WWW::Form::UrlEncoded qw(parse_urlencoded);

sub handle_payment {
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;

    my $borrowernumber = $params->{BiillerReference};
    my $token          = $params->{InvoiceNumber};
    my $amount         = $params->{PaymentAmount};

    my $dbh      = C4::Context->dbh;
    my $query    = "SELECT * FROM cloud_invoice_plugin_tokens WHERE token = ?";
    my $token_hr = $dbh->selectrow_hashref( $query, undef, $token );
    my @accountlines_ids = split( /,/, $token_hr->{accountline_ids} );

    return $c->render(
        status  => 404,
        openapi => { error => "InvoiceNumber not found" }
    ) unless $token_hr;

    my $patron = Koha::Patrons->find($borrowernumber);

    return $c->render(
        status  => 404,
        openapi => { error => "Patron not found" }
    ) unless $patron;

    my $account = $patron->account;

    my $schema = Koha::Database->new->schema;

    my @lines = Koha::Account::Lines->search(
        { accountlines_id => { -in => \@accountlines_ids } } );
    warn "ACCOUNTLINES TO PAY: " . Data::Dumper::Dumper( $_->unblessed )
      for @lines;

    my $payment = $schema->txn_do(
        sub {
            $dbh->do( "DELETE FROM cloud_invoice_plugin_tokens WHERE token = ?",
                undef, $token );

            return $account->pay(
                {
                    amount     => $amount,
                    note       => 'Paid via CloudInvoice',
                    library_id => $patron->branchcode,
                    lines      => \@lines,
                }
            );
        }
    );

    warn "PAYMENT: " . Data::Dumper::Dumper($payment);

    return $c->render( status => 204, text => q{} ) if $payment->{payment_id};

    return $c->render(
        status  => 500,
        openapi => { error => "Payment failed" }
    );
}

1;
