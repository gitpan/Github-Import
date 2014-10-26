use MooseX::Declare;

class Github::Import with MooseX::Getopt {
    # for the PAUSE indexer
    package Github::Import;
    use Moose::Util::TypeConstraints qw(enum);
    use MooseX::Types::Path::Class qw(Dir File);
    use LWP::UserAgent;
    use HTTP::Request::Common 'POST';
    use URI;
    use String::TT 'tt';
    use File::pushd 'pushd';
    use Path::Class;
    use Carp qw(croak);
    use Git;

    use namespace::clean -except => 'meta';

    our $VERSION = "0.03";

    has use_config_file => (
        traits  => [qw(NoGetopt)],
        isa     => "Bool",
        is      => "ro",
        default => 0,
    );

    has config_file => (
        traits        => [qw(Getopt)],
        isa           => File,
        is            => "ro",
        coerce        => 1,
        cmd_flag      => "config-file",
        cmd_aliases   => "f",
        documentation => "Use an alternate config file",
    );

    sub _git_conf {
        my ( $self, $method, $var, $default ) = @_;

        return $default unless $self->use_config_file;

        local $ENV{GIT_CONFIG} = $self->config_file->stringify if $self->has_config_file;

        if ( defined( my $value = $self->git_handle->$method($var) ) ) {
            return $value;
        } else {
            return $default;
        }
    }

    sub _conf_var {
        my ( $self, @args ) = @_;
        $self->_git_conf( config => @args );
    }

    sub _conf_bool {
        my ( $self, @args ) = @_;
        $self->_git_conf( config_bool => @args );
    }

    has git_handle => (
        traits => [qw(NoGetopt)],
        isa => "Git",
        is  => "ro",
        lazy_build => 1,
    );

    sub _build_git_handle {
        my $self = shift;
        Git->repository( Directory => $self->project );
    }

    # command-line args
    has username => (
        traits      => [qw(Getopt)],
        is          => 'ro',
        isa         => 'Str',
        lazy_build  => 1,
        cmd_aliases => "u",
        documentation => 'username for github.com (defaults to $ENV{USER})',
    );

    sub _build_username {
        my $self = shift;
        $self->_conf_var( 'github-import.user' ) || $self->_conf_var( 'github.user' => $ENV{USER} );
    }

    has token => (
        traits      => [qw(Getopt)],
        is          => 'ro',
        isa         => 'Str',
        lazy_build  => 1,
        cmd_aliases => "P",
        documentation => "api token for github.com",
    );

    sub _build_token {
        my $self = shift;
        $self->_conf_var('github-import.token') || $self->_conf_var('github.token') || croak "'token' is required";
    }

    has dry_run => (
        traits      => [qw(Getopt)],
        isa         => "Bool",
        is          => "ro",
        cmd_flag    => "dry-run",
        cmd_aliases => "n",
        documentation => "don't actually do anything",
    );

    has 'project' => (
        traits        => [qw(Getopt)],
        is            => 'ro',
        isa           => Dir,
        default       => ".",
        coerce        => 1,
        cmd_aliases   => "d",
        documentation => "the directory of the repository (default is pwd)",
    );

    has project_name => (
        traits        => [qw(Getopt)],
        is            => 'ro',
        isa           => 'Str',
        default       => sub {
            my $self = shift;
            return lc Path::Class::File->new($self->project->absolute)->basename;
        },
        cmd_flag      => "project-name",
        cmd_aliases   => "N",
        documentation => "the name of the project to create",
    );

    has create => (
        traits        => [qw(Getopt)],
        is            => 'ro',
        isa           => 'Bool',
        lazy_build    => 1,
        cmd_aliases   => "c",
        documentation => "create the repo on github.com (default is true)",
    );

    sub _build_create { shift->_conf_bool( 'github-import.create' => 1 ) }

    has push => (
        traits        => [qw(Getopt)],
        is            => 'ro',
        isa           => 'Bool',
        lazy_build    => 1,
        cmd_aliases   => "p",
        documentation => "run git push (default is true)",
    );

    sub _build_push { shift->_conf_bool( 'github-import.push' => 1 ) }

    has add_remote => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => "Bool",
        cmd_flag      => "add-remote",
        lazy_build    => 1,
        cmd_aliases   => "a",
        documentation => "add a remote for github to .git/config (defaults to true)",
    );

    sub _build_add_remote { shift->_conf_bool( 'github-import.add_remote' => 1 ) }

    has push_tags => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => "Bool",
        cmd_flag      => "tags",
        lazy_build    => 1,
        cmd_aliases   => "t",
        documentation => "specify --tags to push (default is true)",
    );

    sub _build_push_tags { shift->_conf_bool( 'github-import.push_tags' => 1 ) }

    has push_mode => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => enum([qw(all mirror)]),
        predicate     => "has_push_mode",
        cmd_flag      => "push-mode",
        cmd_aliases   => "m",
        documentation => "'all' or 'mirror', overrides other push options",
    );

    has remote => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => "Str",
        lazy_build    => 1,
        cmd_aliases   => "r",
        documentation => "the remote to add to .git/config (default is 'github')",
    );

    sub _build_remote { shift->_conf_var( 'github-import.remote' => "github" ) }

    has refspec => (
        traits        => [qw(Getopt)],
        is            => "ro",
        isa           => "Str",
        lazy_build    => 1,
        cmd_aliases   => "b",
        documentation => "the refspec to specify to push (default is 'master')",
    );

    sub _build_refspec { shift->_conf_var( 'github-import.refspec' => "master" ) }

    has push_uri => (
        traits        => [qw(Getopt)],
        isa           => "Str",
        is            => "ro",
        lazy          => 1,
        default       => sub {
            my $self = shift;
            tt 'git@github.com:[% self.username %]/[% self.project_name %].git';
        },
        cmd_flag      => "push-uri",
        cmd_aliases   => "u",
        documentation => "override the default github push uri",
    );

    # internals
    has 'user_agent' => (
        traits   => ['NoGetopt'],
        is       => 'ro',
        isa      => 'LWP::UserAgent',
        default  => sub { LWP::UserAgent->new( requests_redirectable => [qw/GET POST/] ) }
    );

    has 'logger' => (
        traits  => ['NoGetopt'],
        is      => 'ro',
        isa     => 'CodeRef',
        default => sub {
            sub { print {*STDERR} @_, "\n" },
        },
    );

    method msg(Str $msg){
        $self->logger->($msg);
    }

    method err(Str $msg){
        croak $msg;
    }

    method BUILD(HashRef $args){
        my $p = $self->project;
        confess "project '$p' does not exist" unless -d $p;
    }

    method run(){
        if($self->create){
            $self->msg('Adding project to github');
            my $url = $self->do_create;
            $self->msg('Project added OK: '. $url);
        }

        if($self->add_remote){
            $self->msg(tt 'Adding remote "[% self.remote %]" to existing working copy');
            $self->do_add_remote;
            $self->msg('Remote added');
        };

        if($self->push){
            $self->msg('Pushing existing master to github');
            $self->do_push;
            $self->msg('Pushed OK');
        }
    };

    #my $CREATE_URI = URI->new('http://github.com/repositories/new');
    my $CREATE_SUBMIT_URI = URI->new('http://github.com/repositories');
    method do_create(){
        unless ( $self->dry_run ) {
            my $res = $self->user_agent->request(
                POST( $CREATE_SUBMIT_URI, [
                    'repository[name]'   => $self->project_name,
                    'repository[public]' => 'true',
                    'commit'             => 'Create repository',
                    'login'              => $self->username,
                    'token'              => $self->token,
                ]),
            );

            # XXX: not sure how to detect errors here, other than the obvious
            $self->err('Error creating project: ' . $res->status_line) unless $res->is_success;
        }
        return tt 'http://github.com/[% self.username %]/[% self.project_name %]/tree/master';
    };

    method run_git(ArrayRef $command, Bool :$ignore_errors, Bool :$print_output){
        if ( $self->dry_run ) {
            $self->msg("git @$command");
        } else {
            my $method = $print_output ? "command_noisy" : "command";
            $self->git_handle->$method(@$command);
        }
    }

    method do_add_remote() {
        my $remote = $self->remote;
        my $push   = $self->push_uri;

        if ( defined( my $url = $self->_conf_var("remote.${remote}.url") ) ) {
            if ( $url ne $push ) {
                $self->err("remote $remote is already configured as $url");
            } else {
                $self->msg("remote $remote already added");
            }
        } else {
            $self->run_git(
                [qw(remote add), $remote, $push],
                ignore_errors => 1,
                print_output  => 0,
            );
        }
    }

    method do_push() {
        my $remote = $self->add_remote ? $self->remote : $self->push_uri;
        my $refspec = $self->refspec;

        my @args = $self->has_push_mode
            ? ( "--" . $self->push_mode, $self->remote )
            : ( $self->push_tags ? "--tags" : (), $remote, $self->refspec );

        $self->run_git(
            [ push => @args ],
            print_output => 1,
        );
    }
};

1;

__END__

=pod

=head1 NAME

Github::Import - Import your project into L<http://github.com>

=head1 SYNOPSIS

    % cd some_project_in_git
    % github-import --username jrockway --token decafbad --add-remote --push-mode all

You can also create a config file. Here is an example using a real man's editor:

    % git config --add github.user jrockway
    % git config --add github.token 91ceb00b1es
    % git config --add github-import.remote origin # if you don't like "github"
    % cd some_other_project_in_git
    % github-import

=head1 DESCRIPTION

This class/script provides a way to import a git repository into
L<http://github.com>.

=head1 CONFIGURATION

The standard git configuration file is used to obtain values for the attributes
listed below.

If no value is specified in the config file, the default one in the
documentation will be used.

For instance to not push to github, set:

    [github-import]
        push: false

You can override on the command line by specifying C<--no-push> or C<--push>
depending on what you have in the file and what is the default.

All variables are taken from C<github-import> except C<username> and C<token>
which also fall back to C<github.user> and C<github.token>.

=head1 ATTRIBUTES

=over 4

=item dry_run

If true nothing will actually be done, but the output will be printed.

This is a YAML file containing values for attributes.

=item config_file

Sets C<GIT_CONFIG_LOCAL> to override the configuration file.

Will only override an existing C<GIT_CONFIG_LOCAL> if explicitly set.

Defaults to C<~/github-import>

=item use_config_file

Defaults to false.

The C<github-import> command line tool sets this attribute to enable getting
configuration data.

=item username

The username for github.com

If none is provided or in the config file uses C<$ENV{USER}>.

=item token

The api token for github.com

=item remote

The name of the remote to create if C<add_remote> is specified.

Defaults to C<github>.

=item project

The directory to imoport.

Defaults to the current directory.

=item project_name

The project name to use when creating on github.

Defaults to the basename of C<project>.

=item create

If true a repository will be created on github.

Defaults to true. Requires C<username> and C<password>.

=item add_remote

If true a remote will be added for the github repository.

Defaults to true.

=item push

If true the repository will be pushed to github.

Defaults to true.

=item tags

If true C<--tags> will be given to C<git push>.

Defaults to true.

=item refspec

The refspec to push, given to C<git push>.

Defaults to C<master>.

If you want to push all your branches set to C<refs/heads/*:refs/heads/*>.

=item push_mode

One of C<all> or C<mirror>.

If specified, C<git push --all> or C<git push --mirror> is run instead of
pushing with a refspec.

Overrides C<refspec> and C<tags>.

=item push_uri

Defaults to the SSH push URI for your github repository.

=back

=head1 METHODS

=over 4

=item new_with_options

L<MooseX::Getopt>

=item run

Import the repository by running all steps

=item do_create

Create the repository by submitting a form.

=item do_add_remote

Add a remote entry for github to C<.git/config>.

=item do_push

Run C<git push>.

=back

=head1 VERSION CONTROL

L<http://github.com/jrockway/github-import>

=head1 AUTHORS

Jonathan Rockway

Yuval Kogman

=head1 LICENSE

MIT

=head1 COPYRIGHT

    Copyright 2009 Jonathan Rockway, Yuval Kogman, ALl rights reserved

=cut
