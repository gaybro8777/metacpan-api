package MetaCPAN::Script::Release;
use Moose;
with 'MooseX::Getopt';
with 'MetaCPAN::Role::Common';
use Log::Contextual qw( :log :dlog );

use Path::Class qw(file dir);
use Archive::Tar       ();
use File::Temp         ();
use CPAN::Meta         ();
use DateTime           ();
use List::Util         ();
use Module::Metadata   ();
use File::stat         ('stat');
use CPAN::DistnameInfo ();

use feature 'say';
use MetaCPAN::Script::Latest;
use DateTime::Format::Epoch::Unix;
use File::Find::Rule;
use Try::Tiny;
use LWP::UserAgent;
use MetaCPAN::Document::Author;

has latest  => ( is => 'ro', isa => 'Bool', default => 0 );
has age     => ( is => 'ro', isa => 'Int' );
has childs  => ( is => 'ro', isa => 'Int', default => 2 );

sub run {
    my $self = shift;
    my ( undef, @args ) = @{ $self->extra_argv };
    my @files;
    for (@args) {
        if ( -d $_ ) {
            log_info { "Looking for tarballs in $_" };
            my $find = File::Find::Rule->new->file->name('*.tar.gz');
            $find = $find->mtime( ">" . ( time - $self->age * 3600 ) )
              if ( $self->age );
            push( @files, sort $find->in($_) );
        } elsif ( -f $_ ) {
            push( @files, $_ );
        } elsif ( $_ =~ /^https?:\/\// && CPAN::DistnameInfo->new($_)->cpanid )
        {
            my $d = CPAN::DistnameInfo->new($_);
            my $file =
              Path::Class::File->new( qw(var tmp http),
                                      'authors',
                                      MetaCPAN::Document::Author::_build_dir(
                                                                      $d->cpanid
                                      ),
                                      $d->filename );
            my $ua = LWP::UserAgent->new( parse_head => 0,
                                          env_proxy  => 1,
                                          agent      => "metacpan",
                                          timeout    => 30, );
            $file->dir->mkpath;
            log_info { "Downloading $_" };
            $ua->mirror( $_, $file );
            if ( -e $file ) {
                push( @files, $file );
            } else {
                log_error { "Downloading $_ failed" };
            }
        } else {
            log_error { "Dunno what $_ is" };
        }
    }
    log_info { scalar @files, " tarballs found" } if ( @files > 1 );
    my @pid;
    while ( my $file = shift @files ) {
        if(@pid >= $self->childs) {
            my $pid = waitpid( -1, 0);
            @pid = grep { $_ != $pid } @pid;
        }
        if(my $pid = fork()) {
            push(@pid, $pid);
        } else {
                try { $self->import_tarball($file) }
                catch {
                    log_fatal { $_ };
                };
                exit;
        };
    }
    waitpid( -1, 0);
}

sub import_tarball {
    my ( $self, $tarball ) = @_;
    my $cpan = $self->model->index('cpan');

    log_info { "Processing $tarball" };
    $tarball = Path::Class::File->new($tarball);

    log_debug { "Opening tarball in memory" };
    my $at     = Archive::Tar->new($tarball);
    my $tmpdir = dir(File::Temp::tempdir);
    my $d      = CPAN::DistnameInfo->new($tarball);
    my $date = $self->pkg_datestamp($tarball);
    my ( $author, $archive, $name ) =
      ( $d->cpanid, $d->filename, $d->distvname );
    my $version = MetaCPAN::Util::fix_version( $d->version );
    my $meta = CPAN::Meta->new(
                                { version => $version || 0,
                                  license => 'unknown',
                                  name    => $d->dist,
                                  no_index => { directory => [qw(t xt inc)] } }
    );

    my @files;
    my $meta_file;
    log_debug { "Gathering files" };
    my @list = $at->get_files;
    while ( my $child = shift @list ) {
        if ( ref $child ne 'HASH' ) {
            $meta_file = $child if ( !$meta_file && $child->full_path =~ /^[^\/]+\/META\./ || $child->full_path =~ /^[^\/]+\/META\.json/ );
            my $stat = { map { $_ => $child->$_ } qw(mode uid gid size mtime) };
            next unless ( $child->full_path =~ /\// );
            ( my $fpath = $child->full_path ) =~ s/.*?\///;
            my $fname = $fpath;
            $child->is_dir
              ? $fname =~ s/^(.*\/)?(.+?)\/?$/$2/
              : $fname =~ s/.*\///;
            push(
                @files,
                Dlog_trace { "adding file $_" } +{
                    name         => $fname,
                    directory    => $child->is_dir ? 1 : 0,
                    release      => $name,
                    date => $date,
                    distribution => $meta->name,
                    author       => $author,
                    full_path    => $child->full_path,
                    path         => $fpath,
                    stat         => $stat,
                    maturity     => $d->maturity,
                    indexed => 1,
                    content_cb =>
                      sub { \( $at->get_content( $child->full_path ) ) }
                } );
        }
    }

    #  YAML YAML::Tiny YAML::XS don't offer better results
    my @backends = qw(CPAN::Meta::YAML YAML::Syck)
        if ($meta_file);
    while(my $mod = shift @backends) {
        $ENV{PERL_YAML_BACKEND} = $mod;
        my $last;
        try {
            $at->extract_file( $meta_file, $tmpdir->file( $meta_file->full_path ) );
            my $foo = $last =
              CPAN::Meta->load_file( $tmpdir->file( $meta_file->full_path ) );
            $meta = $foo;
        }
        catch {
            log_warn { "META file could not be loaded using $mod: $_" };
        };
        last if($last);
    }

    my $no_index = $meta->no_index;
    foreach my $no_dir ( @{ $no_index->{directory} || [] }, qw(t xt inc) ) {
        map { $_->{indexed} = 0 }
          grep { $_->{path} =~ /^\Q$no_dir\E\// } @files;
    }

    foreach my $no_file ( @{ $no_index->{file} || [] } ) {
        map { $_->{indexed} = 0 } grep { $_->{path} =~ /^\Q$no_file\E/ } @files;
    }

    log_debug { "Indexing ", scalar @files, " files" };
    my $i = 1;
    my $file_set = $cpan->type('file');
    foreach my $file (@files) {
        my $obj = $file_set->put($file);
        $file->{abstract} = $obj->abstract;
        $file->{id}       = $obj->id;
        $file->{module}   = {};
    }
    my $st = stat($tarball);
    my $stat = { map { $_ => $st->$_ } qw(mode uid gid size mtime) };
    my $create =
      { map { $_ => $meta->$_ } qw(version name license abstract resources) };

    $create->{abstract} = MetaCPAN::Util::strip_pod($create->{abstract});

    $create = DlogS_trace { "adding release $_" }
    +{  %$create,
        name         => $name,
        author       => $author,
        distribution => $meta->name,
        archive      => $archive,
        maturity     => $d->maturity,
        stat         => $stat,
        date         => $date, };

    my $release = $cpan->type('release')->put($create);
    
    my $distribution =
      $cpan->type('distribution')->put( { name => $meta->name } );
    
    log_debug { "Gathering dependencies" };

    # find dependencies
    my @dependencies;
    if ( my $prereqs = $meta->prereqs ) {
        while ( my ( $phase, $data ) = each %$prereqs ) {
            while ( my ( $relationship, $v ) = each %$data ) {
                while ( my ( $module, $version ) = each %$v ) {
                    push( @dependencies,
                          Dlog_trace { "adding dependency $_" }
                          +{  phase        => $phase,
                              relationship => $relationship,
                              module       => $module,
                              version      => $version,
                              author       => $author,
                              release      => $release->name,
                          } );
                }
            }
        }
    }

    log_debug { "Indexing ", scalar @dependencies, " dependencies" };
    $i = 1;
    my $dep_set = $cpan->type('dependency');
    foreach my $dependencies (@dependencies) {
        $dependencies = $dep_set->put($dependencies);
    }

    log_debug { "Gathering modules" };

    # find modules
    my @modules;
    if ( keys %{ $meta->provides } && ( my $provides = $meta->provides ) ) {
        while ( my ( $module, $data ) = each %$provides ) {
            my $path = $data->{file};
            my $file = List::Util::first { $_->{path} =~ /\Q$path\E$/ } @files;
            $file->{module}->{$module} = $data;
            push(@modules, $file);
        }

    }
    @files = grep { $_->{name} =~ /\.pod$/i || $_->{name} =~ /\.pm$/ } grep { $_->{indexed} } @files;

    foreach my $file (@files) {
        eval {
            local $SIG{'ALRM'} = sub {
                log_error { "Call to Module::Metadata timed out " };
                die;
            };
            alarm(5);
            $at->extract_file( $file->{full_path},
                               $tmpdir->file( $file->{full_path} ) );
            my $info;
            {
                local $SIG{__WARN__} = sub { };
                $info = Module::Metadata->new_from_file(
                                          $tmpdir->file( $file->{full_path} ) );
            }
            $file->{module}->{$_} ||= 
                  {  $info->version
                     ? ( version => $info->version->numify )
                     : () } for ( $info->packages_inside );
            push(@modules, $file);
            alarm(0);
        };
    }

    log_debug { "Indexing ", scalar @modules, " modules" };
    $i = 1;
    my $mod_set = $cpan->type('module');
    foreach my $file (@modules) {
        my @modules = map { { name => $_, %{$file->{module}->{$_}} } } keys %{$file->{module}};
        my %module = @modules ? (module => \@modules) : ();
        delete $file->{module};
        $file = MetaCPAN::Document::File->new( %$file, %module, index => $cpan );
        $file->clear_indexed;
        log_trace { "reindexing file $file->{path}" };
        Dlog_trace { $_ } $file->meta->get_data($file);
        $file->put;
    }
    
    $tmpdir->rmtree;

    if ( $self->latest ) {
        local @ARGV = ( qw(latest --distribution), $release->distribution );
        MetaCPAN::Script::Runner->run;
    }
}

sub pkg_datestamp {
    my $self    = shift;
    my $archive = shift;
    my $date    = stat($archive)->mtime;
    return DateTime::Format::Epoch::Unix->parse_datetime($date);

}

1;

__END__

=head1 SYNOPSIS

 # bin/metacpan ~/cpan/authors/id/A
 # bin/metacpan ~/cpan/authors/id/A/AB/ABRAXXA/DBIx-Class-0.08127.tar.gz
 # bin/metacpan http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/CPAN-Meta-2.110580.tar.gz

 # bin/metacpan ~/cpan --age 24 --latest

=head1 DESCRIPTION

This is the workhorse of MetaCPAN. It accepts a list of folders, files or urls
and indexes the releases. Adding C<--latest> will set the status to C<latest>
for the indexed releases If you are indexing more than one release, running
L<MetaCPAN::Script::Latest> afterwards is probably faster.

C<--age> sets the maximum age of the file in hours. Will be ignored when processing
individual files or an url.

If an url is specified the file is downloaded to C<var/tmp/http/>. This folder is not
cleaned up since L<MetaCPAN::Plack::Source> depends on it to extract the source of
a file. If the tarball cannot be find in the cpan mirror, it tries the temporary
folder. After a rsync this folder can be purged.