package Backblaze::B2;
use strict;
use vars qw($VERSION);
$VERSION = '0.01';

=head1 NAME

Backblaze::B2 - interface to the Backblaze B2 API

=head1 SYNOPSIS

=head1 METHODS

=head2 C<< Backblaze::B2->new %options >>

=over 4

=item B<< version >>

Allows you to specify the API version. The current
default is C<< v1 >>, which corresponds to the
Backblaze B2 API version 1 as documented at
L<https://www.backblaze.com/b2/docs/>.

=back

=cut

sub new {
    my( $class, %options ) = @_;
    $options{ version } ||= 'v1';
    $class = "$class\::$options{ version }";
    $class->new( %options );
};

=head1 SETUP

=over 4

=item 0

Have a telephone / mobile phone number you're willing to
share with Backblaze

=item 1

Register at for Backblaze B2 Cloud Storage at 

L<https://secure.backblaze.com/account_settings.htm?showPhone=true>

=item 2

Add the phone number to your account at

L<https://secure.backblaze.com/account_settings.htm?showPhone=true>

=item 2

Enable Two-Factor verification through your phone at

L<https://secure.backblaze.com/account_settings.htm?showPhone=true>

=item 3

Create a JSON file named C<B2.credentials> in your home directory
with the application key and the account key:

    { "accountId":      "...",
      "applicationKey": ".............."
    }


=cut

package Backblaze::B2::v1;
use strict;
use vars qw($AUTOLOAD);
use Carp qw(croak);
use JSON::XS 'decode_json';

use vars '$API_BASE';
$API_BASE = 'https://api.backblaze.com/b2api/v1/';

sub api { $_[0]->{api} }

sub new {
    my( $class, %options ) = @_;
    
    $options{ api } ||= Backblaze::B2::v1::AnyEvent->new(
        api_base => $API_BASE,
        %options
    );
    
    bless \%options => $class;
}

sub read_credentials {
    my( $self, @args ) = @_;
    $self->api->read_credentials(@args)
}

sub AUTOLOAD {
    my( $self, @arguments ) = @_;
    $AUTOLOAD =~ /::([^:]+)$/
        or croak "Invalid method name '$AUTOLOAD' called";
    my $method = $1;
    $self->api->can( $method )
        or croak "Unknown method '$method' called on $self";

    # Install the subroutine for caching
    my $namespace = ref $self;
    no strict 'refs';
    my $new_method = *{"$namespace\::$method"} = sub {
        my $self = shift;
        my( $ok, $msg, @results) = $self->api->$method( @_ )->recv;
        if( ! $ok ) {
            croak $msg;
        } else {
            return @results
        };
    };

    # Invoke the newly installed method
    goto &$new_method;
};

package Backblaze::B2::v1::AnyEvent;
use strict;
use JSON::XS;
use MIME::Base64;
use URI::QueryParam;
use Carp qw(croak);

use AnyEvent;
use AnyEvent::HTTP;
#use URI::Template;
use URI;
use Data::Dumper;

sub new {
    my( $class, %options ) = @_;
    
    croak "Need an API base"
        unless $options{ api_base };
    
    bless \%options => $class;
}

sub log_message {
    my( $self ) = shift;
    if( $self->{log_message}) {
        goto &{ $self->{log_message}};
    };
}

sub read_credentials {
    my( $self, $file ) = @_;
    
    if( ! defined $file) {
        require File::HomeDir;
        $file = File::HomeDir->my_home . "/credentials.b2";
        $self->log_message(0, "Using default credentials file '$file'");
    };
    
    $self->log_message(1, "Reading credentials from '$file'");
    
    open my $fh, '<', $file
        or croak "Couldn't read credentials from '$file': $!";
    binmode $fh;
    local $/;
    my $json = <$fh>;
    my $cred = decode_json( $json );
    
    $self->{credentials} = $cred;
    
    $cred
};

sub make_json_response_decoder {
    my( $self, $res ) = @_;
    return sub {
        my($body,$hdr) = @_;
        
        $self->log_message(1, sprintf "Response status %d", $hdr->{Status});

        if( !$body) {
            $self->log_message(4, sprintf "No response body received");
            $res->send(0, "No response body received", $hdr);
        } else {
            
            my $b = eval { decode_json( $body ); };
            if( my $err = $@ ) {
                $self->log_message(4, sprintf "Error decoding JSON response body: %s", $err);
                $res->send(0, sprintf("Error decoding JSON response body: %s", $err), $hdr);
            };
            $res->send(1, "", $b);
        };
        undef $res;
    };
}

# Provide headers from the credentials, if available
sub get_headers {
    my( $self ) = @_;
    if( my $token = $self->authorizationToken ) {
        return Authorization => $token
    };
    return ()
}

sub accountId {
    my( $self ) = @_;
    $self->{credentials}->{accountId}
}

sub authorizationToken {
    my( $self ) = @_;
    $self->{credentials}->{authorizationToken}
}

sub downloadUrl {
    my( $self ) = @_;
    $self->{credentials}->{downloadUrl}
}

sub apiUrl {
    my( $self ) = @_;
    $self->{credentials}->{apiUrl}
}


# You might want to override this if you want to use HIJK or
# some other way. If your HTTP requestor is synchronous, just
# return a
# AnyEvent->condvar
# which performs the real task.
sub request {
    my( $self, %options) = @_;
    
    $options{ method } ||= 'GET';
    my $completed = delete $options{ cb };
    my $method    = delete $options{ method };
    my $endpoint  = delete $options{ api_endpoint };
    my $headers = delete $options{ headers };
    $headers ||= { $self->get_headers };
        
    my $url;
    if( ! $options{url} ) {
        croak "Don't know the api_endpoint for the request"
            unless $endpoint;
        $url = URI->new( join( "/b2api/v1/",
            $self->apiUrl,
            $endpoint)
        );
    } else {
        $url = delete $options{ url };
        $url = URI->new( $url )
            if( ! ref $url );
    };
    for my $k ( keys %options ) {
        my $v = $options{ $k };
        $url->query_param_append($k, $v);
    };
    
    $self->log_message(1, sprintf "Sending %s request to %s", $method, $url);
    return 
        http_request $method => $url,
            headers => $headers,
            $completed,
    ;
}

sub authorize_account {
    my( $self, %options ) = @_;
    $options{ accountId }
        or croak "Need an accountId";
    $options{ applicationKey }
        or croak "Need an applicationKey";
    my $auth= encode_base64( "$options{accountId}:$options{ applicationKey }" );

    my $res = AnyEvent->condvar();
    my $handle;
    my $store_credentials = sub {
        
        my( $cv ) = @_;
        my( $ok, $msg, $cred ) = $cv->recv;
        $self->log_message(1, sprintf "Storing authorization token");
        $self->{credentials} = $cred;
        undef $self;
        undef $handle;
        $res->send($ok, $msg, $cred);
    };    
    my $got_credentials = AnyEvent->condvar( cb => $store_credentials );
    my $url = $self->{api_base} . "b2_authorize_account";
    $handle = $self->request(
        url => $url,
        headers => {
            "Authorization" => "Basic $auth"
        },
        cb => $self->make_json_response_decoder($got_credentials),
    );
        
    $res
}

=head2 C<< $b2->create_bucket >>

  $b2->create_bucket(
      bucketName => 'my_files',
      bucketType => 'allPrivate',
  );

Bucket names can consist of: letters, digits, "-", and "_". 

L<https://www.backblaze.com/b2/docs/b2_create_bucket.html>

The C<bucketName> has to be B<globally> unique, so expect
this request to fail, a lot.

=cut

sub create_bucket {
    my( $self, %options ) = @_;
    
    croak "Need a bucket name"
        unless defined $options{ bucketName };
    $options{ accountId } ||= $self->accountId;
    $options{ bucketType } ||= 'allPrivate'; # let's be defensive here...
    
    my $res = AnyEvent->condvar;
    my $guard; $guard = $self->request(api_endpoint => 'b2_create_bucket',
        accountId => $options{ accountId },
        bucketName => $options{ bucketName },
        bucketType => $options{ bucketType },
        cb => $self->make_json_response_decoder($res),
        %options
    );
    
    $res
}

=head2 C<< $b2->delete_bucket >>

  $b2->delete_bucket(
      bucketId => ...,
  );

Bucket names can consist of: letters, digits, "-", and "_". 

L<https://www.backblaze.com/b2/docs/b2_delete_bucket.html>

The bucket must be empty of all versions of all files.

=cut

sub delete_bucket {
    my( $self, %options ) = @_;
    
    croak "Need a bucketId"
        unless defined $options{ bucketId };
    $options{ accountId } ||= $self->accountId;
    
    my $res = AnyEvent->condvar;
    my $guard; $guard = $self->request(api_endpoint => 'b2_delete_bucket',
        accountId => $options{ accountId },
        bucketId => $options{ bucketId },
        cb => $self->make_json_response_decoder($res),
        %options
    );
    
    $res
}

=head2 C<< $b2->list_buckets >>

  $b2->list_buckets();

L<https://www.backblaze.com/b2/docs/b2_listbuckets.html>

=cut

sub list_buckets {
    my( $self, %options ) = @_;
    
    $options{ accountId } ||= $self->accountId;
    
    my $res = AnyEvent->condvar;
    my $guard; $guard = $self->request(api_endpoint => 'b2_list_buckets',
        accountId => $options{ accountId },
        cb => $self->make_json_response_decoder($res),
        %options
    );
    
    $res
}

1;