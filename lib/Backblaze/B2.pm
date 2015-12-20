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

=item 0. Have a telephone / mobile phone number you're willing to
share with Backblaze

=item 1. Register at for Backblaze B2 Cloud Storage at 

L<https://secure.backblaze.com/account_settings.htm?showPhone=true>

=item 2. Add the phone number to your account at

L<https://secure.backblaze.com/account_settings.htm?showPhone=true>

=item 2. Enable Two-Factor verification through your phone at

L<https://secure.backblaze.com/account_settings.htm?showPhone=true>

=item 3. Create a JSON file named C<B2.credentials>

This file should live in your
home directory
with the application key and the account key:

    { "accountId":      "...",
      "applicationKey": ".............."
    }


=cut

package Backblaze::B2::v1;
use strict;

=head1 NAME

Backblaze::B2::v1 - Backblaze B2 API account

=head1 METHODS

=head2 C<< ->new %options >>

    my $b2 = Backblaze::B2::v1->new(
        api => 'Backblaze::B2::v1::Synchronous', # the default
    );

Creates a new instance. Depending on whether you pass in
C<<Backblaze::B2::v1::Synchronous>> or C<<Backblaze::B2::v1::AnyEvent>>,
you will get a synchronous or asynchronous API.

The synchronous API is what is documented here, as this is the
most likely use case.

    my @buckets = $b2->buckets();
    for( @buckets ) {
        ...
    }

The asynchronous API is identical to the synchronous API in spirit, but
will return L<AnyEvent> condvar's. These condvars return
two or more parameters upon completion:

    my $cv = $b2->buckets();
    my( $ok, $msg, @buckets ) = $cv->recv();
    if( ! $ok ) {
        die "Error: $msg";
    };
    for( @buckets ) {
        ...
    }

The asynchronous API puts the burden of error handling into your code.

=cut

sub new {
    my( $class, %options ) = @_;
    
    $options{ api } ||= 'Backblaze::B2::v1::Synchronous';
    $options{ bucket_class } ||= 'Backblaze::B2::v1::Bucket';
    $options{ file_class } ||= 'Backblaze::B2::v1::File';
    if( ! ref $options{ api }) {
        eval "require $options{ api }";
        $options{ api } = $options{ api }->new();
    };
    
    bless \%options => $class
}

sub read_credentials {
    my( $self, @args ) = @_;
    $self->api->read_credentials(@args)
}

sub _new_bucket {
    my( $self, %options ) = @_;
    # Should this one magically unwrap AnyEvent::condvar objects?!
    $self->{bucket_class}->new(
        %options,
        api => $self->api,
        parent => $self,
        file_class => $self->{file_class}
    )
}

=head2 C<< ->buckets >>

    my @buckets = $b2->buckets();

Returns a list of L<Backblaze::B2::Bucket> objects associated with
the B2 account.

=cut

sub buckets {
    my( $self ) = @_;
    warn "Listing buckets";
    my $list = $self->api->list_buckets();
    map { $self->_new_bucket( %$_ ) }
        @{ $list->{buckets} }
}

=head2 C<< ->create_bucket >>

    my $new_bucket = $b2->create_bucket(
        name => 'my-new-bucket', # only /[A-Za-z0-9-]/i are allowed as bucket names
        type => 'allPrivate', # or allPublic
    );
    
    print sprintf "Created new bucket %s\n", $new_bucket->id;

Creates a new bucket and returns it.

=cut

sub create_bucket {
    my( $self, %options ) = @_;
    $options{ type } ||= 'allPrivate';
    my $bucket = $self->api->create_bucket(
        bucketName => $options{ name },
        bucketType => $options{ type },
    );
    $self->_new_bucket( %$bucket );
}

=head2 C<< ->api >>

Returns the underlying API object

=cut

sub api { $_[0]->{api} }

1;

package Backblaze::B2::v1::Bucket;
use strict;
use Scalar::Util 'weaken';

sub new {
    my( $class, %options ) = @_;
    weaken $options{ parent };
    bless \%options => $class,
}

sub name { $_[0]->{bucketName} }
sub id { $_[0]->{bucketId} }
sub type { $_[0]->{bucketType} }
sub account { $_[0]->{parent} }

sub _new_file {
    my( $self, %options ) = @_;
    # Should this one magically unwrap AnyEvent::condvar objects?!
    $self->{file_class}->new(
        %options,
        api => $self->api,
        bucket => $self
    );
}

=head2 C<< ->files( %options ) >>

Lists the files contained in this bucket

    my @files = $bucket->files(
        startFileName => undef,
    );

By default it returns only the first 1000
files, but see the C<allFiles> parameter.

=over 4

=item C<< allFiles >>

    allFiles => 1

Passing in a true value for this parameter will make
as many API calls as necessary to fetch all files.

=back

=cut

sub files {
    my( $self, %options ) = @_;
    $options{ maxFileCount } ||= 1000;
    $options{ startFileName } ||= undef;
    
    my @res;
    
    my $fetch_more= 1;
    while( $fetch_more ) {
        my $files = $self->api->list_files(
            bucketId => $self->id,
            %options,
        );
        push @res, @{ $files->{files} };
        $fetch_more = $options{ allFiles } && $files->{endFileName};
    };
    map { $self->_new_file( %$_, folder => $self ) } @res
}

=head2 C<< ->upload_file( %options ) >>

Uploads a file into this bucket, potentially creating
a new file version.

    my $new_file = $bucket->upload_file(
        file => 'some/local/file.txt',
        target_file => 'the/public/name.txt',
    );

=over 4

=item C<< file >>

Local name of the source file. This file will be loaded
into memory in one go.

=item C<< target_file >>

Name of the file on the B2 API. Defaults to the local name.

The target file name will have backslashes replaced by forward slashes
to comply with the B2 API.

=item C<< mime_type >>

Content-type of the stored file. Defaults to autodetection by the B2 API.

=item C<< content >>

If you don't have the local content in a file on disk, you can
pass the content in as a string.

=item C<< mtime >>

Time in miliseconds since the epoch to when the content was created.
Defaults to the current time.

=item C<< sha1 >>

Hexdigest of the SHA1 of the content. If this is missing, the SHA1
will be calculated upon upload.

=back

=cut

sub upload_file {
    my( $self, %options ) = @_;

    # XXX We are synchronous here!
    my $upload_handle = $self->api->get_upload_url(
        bucketId => $self->id,
    );
    my @res = $self->api->upload_file(
        %options,
        handle => $upload_handle
    );

    (my $res) = map { $self->_new_file( %$_, folder => $self ) } @res;
    $res
}

=head2 C<< ->api >>

Returns the underlying API object

=cut

sub api { $_[0]->{api} }

package Backblaze::B2::v1::File;
use strict;
use Scalar::Util 'weaken';

sub new {
    my( $class, %options ) = @_;
    weaken $options{ folder };
    bless \%options => $class,
}

sub name { $_[0]->{fileName} }
sub id { $_[0]->{fileId} }
sub action { $_[0]->{action} }
sub folder { $_[0]->{folder} }
sub size { $_[0]->{size} }

1;

package Backblaze::B2::v1::Synchronous;
use strict;
use vars qw($AUTOLOAD);
use Carp qw(croak);
use JSON::XS 'decode_json';

use vars '$API_BASE';
$API_BASE = 'https://api.backblaze.com/b2api/v1/';

sub api { $_[0]->{api} }

=head1 METHODS

=head2 C<< ->new >>

Creates a new synchronous instance.

=cut

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
            return wantarray ? @results : $results[0]
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
use URI::Escape;
use Digest::SHA1;
use File::Basename;
use Encode;
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
    my( $self, $res, $req ) = @_;
    
    die "Need a HTTP request handle to hold on to"
        unless $req;
    
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
        undef $req;
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
    my $headers = delete $options{ headers } || {};
    $headers = { $self->get_headers, %$headers };
    my $body = delete $options{ _body };
        
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
            body => $body,
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
    my $store_credentials = sub {
        
        my( $cv ) = @_;
        my( $ok, $msg, $cred ) = $cv->recv;
        $self->log_message(1, sprintf "Storing authorization token");
        $self->{credentials} = $cred;
        undef $self;
        $res->send($ok, $msg, $cred);
    };    
    my $got_credentials = AnyEvent->condvar( cb => $store_credentials );
    my $url = $self->{api_base} . "b2_authorize_account";
    my $handle; $handle = $self->request(
        url => $url,
        headers => {
            "Authorization" => "Basic $auth"
        },
        cb => $self->make_json_response_decoder($got_credentials, \$handle),
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
        cb => $self->make_json_response_decoder($res, \$guard),
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
        cb => $self->make_json_response_decoder($res, \$guard),
        %options
    );
    
    $res
}

=head2 C<< $b2->list_buckets >>

  $b2->list_buckets();

L<https://www.backblaze.com/b2/docs/b2_list_buckets.html>

=cut

sub list_buckets {
    my( $self, %options ) = @_;
    
    $options{ accountId } ||= $self->accountId;
    
    my $res = AnyEvent->condvar;
    my $guard; $guard = $self->request(api_endpoint => 'b2_list_buckets',
        accountId => $options{ accountId },
        cb => $self->make_json_response_decoder($res, \$guard),
        %options
    );
    
    $res
}

=head2 C<< $b2->get_upload_url >>

  my $upload_handle = $b2->get_upload_url();
  $b2->upload_file( file => $file, handle => $upload_handle );

L<https://www.backblaze.com/b2/docs/b2_get_upload_url.html>

=cut

sub get_upload_url {
    my( $self, %options ) = @_;
    
    croak "Need a bucketId"
        unless defined $options{ bucketId };

    my $res = AnyEvent->condvar;
    my $guard; $guard = $self->request(api_endpoint => 'b2_get_upload_url',
        cb => $self->make_json_response_decoder($res, \$guard),
        %options
    );
    
    $res
}

=head2 C<< $b2->upload_file >>

  my $upload_handle = $b2->get_upload_url();
  $b2->upload_file(
      file => $file,
      handle => $upload_handle
  );

L<https://www.backblaze.com/b2/docs/b2_upload_file.html>

Note: This method loads the complete file to be uploaded
into memory.

Note: The Backblaze B2 API is vague about when you need
a new upload URL.

=cut

sub upload_file {
    my( $self, %options ) = @_;
    
    croak "Need an upload handle"
        unless defined $options{ handle };
    my $handle = delete $options{ handle };

    croak "Need a source file name"
        unless defined $options{ file };
    my $filename = delete $options{ file };
        
    my $target_filename = delete $options{ target_name };
    $target_filename ||= $filename;
    $target_filename =~ s!\\!/!g;
    $target_filename = uri_escape( encode('UTF-8', $target_filename ));
    
    my $mime_type = delete $options{ mime_type } || 'b2/x-auto';
    
    if( not defined $options{ content }) {
        open my $fh, '<', $filename
            or croak "Couldn't open '$filename': $!";
        binmode $fh, ':raw';
        $options{ content } = do { local $/; <$fh> }; # sluuuuurp
        $options{ mtime } = ((stat($fh))[9]) * 1000;
    };

    my $payload = delete $options{ content };
    if( not $options{ sha1 }) {
        my $sha1 = Digest::SHA1->new;
        $sha1->add( $payload );
        $options{ sha1 } = $sha1->hexdigest;
    };
    my $digest = delete $options{ sha1 };
    my $size = length($payload);
    my $mtime = delete $options{ mtime };

    my $res = AnyEvent->condvar;
    my $guard; $guard = $self->request(
        url => $handle->{uploadUrl},
        method => 'POST',
        _body => $payload,
        headers => {
            'Content-Type' => $mime_type,
            'Content-Length' => $size,
            'X-Bz-Content-Sha1' => $digest,
            'X-Bz-File-Name' => $target_filename,
            'Authorization' => $handle->{authorizationToken},
        },
        cb => $self->make_json_response_decoder($res, \$guard),
        %options
    );
    
    $res
}

=head2 C<< $b2->list_files >>

  my $list = $b2->listFiles(
      startFileName => undef,
      maxFileCount => 1000, # maximum per round
      bucketId => ...,
      
  );

L<https://www.backblaze.com/b2/docs/b2_list_files.html>

=cut

sub list_files {
    my( $self, %options ) = @_;
    
    croak "Need a bucket id"
        unless defined $options{ bucketId };

    my $res = AnyEvent->condvar;
    my $guard; $guard = $self->request(
        api_endpoint => 'b2_list_files',
        cb => $self->make_json_response_decoder($res, \$guard),
        %options
    );
    
    $res
}

1;