#!perl -w
use strict;
use JSON::XS;
use Backblaze::B2;
use Getopt::Long;

GetOptions(
    'c|credentials:s' => \my $credentials_file,
);

my ($bucket_id, @files) = @ARGV;

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


for my $file (@files) {
    # Currently we need a new upload URL for every file:
    my $handle = $b2->get_upload_url( bucketId => $bucket_id );
    use Data::Dumper;
    warn Dumper 
    $b2->upload_file(
        file => $file,
        handle => $handle
    );
};
