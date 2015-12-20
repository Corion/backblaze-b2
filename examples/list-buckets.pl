#!perl -w
use strict;
use JSON::XS;
use Backblaze::B2;
use Getopt::Long;

GetOptions(
    'c|credentials:s' => \my $credentials_file,
);

my ($bucket_name) = @ARGV;

=head1 SYNOPSIS

=cut

my $b2 = Backblaze::B2->new(
    version => 'v1',
    log_message => sub { warn sprintf "[%d] %s\n", @_; },
);

my $credentials = $b2->read_credentials( $credentials_file );
if( ! $credentials->{authorizationToken}) {
    $b2->authorize_account(%$credentials);
};

use Data::Dumper;

my $buckets = $b2->list_buckets()->{buckets};

for my $bucket (@$buckets) {
    print join "\t", $bucket->{bucketName}, $bucket->{bucketType}, $bucket->{bucketId};
    print "\n";
};