package Dist::Zilla::Plugin::CheckPrereqsIndexed;
# ABSTRACT: prevent a release if you have prereqs not found on CPAN

use Moose;
with 'Dist::Zilla::Role::BeforeRelease';

# BEGIN BOILERPLATE
use v5.20.0;
use warnings;
use utf8;
no feature 'switch';
use experimental qw(postderef postderef_qq); # This experiment gets mainlined.
# END BOILERPLATE

=head1 OVERVIEW

Sometimes, AutoPrereqs is a little overzealous and finds a prereq that you
wrote inline or have in your F<./t> directory.  Although AutoPrereqs should
grow more accurate over time, and avoid these mistakes, it's not perfect right
now.  CheckPrereqsIndexed will check every required package against the CPAN
index to ensure that they're all real, installable packages.

If any are unknown, it will prompt the user to continue or abort.

Previously, CheckPrereqsIndexed queried CPANIDX, but it now queries
cpanmetadb. This behavior may change again in the future, or it may become
pluggable.  In the meantime, this makes releasing while offline impossible...
but it was anyway, right?

=cut

use List::Util 1.33 qw(any);

use namespace::autoclean;

sub mvp_multivalue_args { qw(skips) }
sub mvp_aliases { return { skip => 'skips' } }

=attr skips

This is an array of regular expressions.  Any module names matching any of
these regex will not be checked.  This should only be necessary if you have a
prerequisite that is not available on CPAN (because it's distributed in some
other way).

=cut

has skips => (
  isa     => 'ArrayRef[Str]',
  default => sub { [] },
  traits  => [ 'Array' ],
  handles => { skips => 'elements' },
);

my %NOT_INDEXED = map {; $_ => 1 }
                  qw(Config DB Errno integer NEXT perl Pod::Functions);

sub before_release {
  my ($self) = @_;

  $self->log("checking prereqs against CPAN index");

  require version;

  my @skips = map {; qr/$_/ } $self->skips;

  my $requirements = CPAN::Meta::Requirements->new;

  # find the package => version for all modules in this distribution
  my $provides = $self->zilla->distmeta->{provides} // {};
  my %self_modules = map { $_ => $provides->{$_}{version} } keys %$provides;

  if (not keys %self_modules) {
    (my $pkg = $self->zilla->name) =~ s/-/::/g;
    $self->log_debug([ 'no "provides" metadata; guessing distribution contains module %s', $pkg ]);
    %self_modules = ( $pkg => $self->zilla->version );
  }

  for my $prereqs_hash (
    $self->zilla->prereqs->as_string_hash,
    (map { $_->{prereqs} } values(($self->zilla->distmeta->{optional_features} // {})->%*)),
  ) {
    for my $phase (keys %$prereqs_hash) {
      for my $type (keys $prereqs_hash->{$phase}->%*) {
        REQ_PKG: for my $pkg (keys $prereqs_hash->{$phase}{$type}->%*) {
          if ($NOT_INDEXED{ $pkg }) {
            $self->log_debug([ 'skipping unindexed module %s', $pkg ]);
            next;
          }

          if (any { $pkg =~ $_ } @skips) {
            $self->log_debug([ 'explicitly skipping module %s', $pkg ]);
            next;
          }

          my $ver = $prereqs_hash->{$phase}{$type}{$pkg};

          # skip packages contained in the distribution we are releasing, from
          # develop prereqs only
          if (
            $phase eq 'develop'
            and exists $self_modules{$pkg}
            and version->parse($self_modules{$pkg}) >= version->parse($ver)
          ) {
            $self->log_debug([ 'skipping develop prereq on ourself (%s => %s)', $pkg, $ver ]);
            next;
          }

          $requirements->add_string_requirement($pkg => $ver);
        }
      }
    }
  }

  my @modules = $requirements->required_modules;
  return unless @modules; # no prereqs!?

  require HTTP::Tiny;
  require YAML::Tiny;

  my $ua = HTTP::Tiny->new;

  my %missing;
  my %unmet;

  PKG: for my $pkg (sort @modules) {
    my $res = $ua->get("http://cpanmetadb.plackperl.org/v1.0/package/$pkg");
    unless ($res->{success}) {
      if ($res->{status} == 404) { # Not found
        $missing{ $pkg } = 1;
        next PKG;
      }
      chomp($res->{content});
      $self->log_fatal(['%s %s: %s', $res->{status}, $res->{reason}, $res->{content}]);
    }

    my $payload = YAML::Tiny->read_string( $res->{content} );

    unless (@$payload) {
      $missing{ $pkg } = 1;
      next PKG;
    }

    my $indexed_version = version->parse($payload->[0]{version});
    next PKG if $requirements->accepts_module($pkg, $indexed_version->stringify);

    $unmet{ $pkg } = {
      required => $requirements->requirements_for_module($pkg),
      indexed  => $indexed_version,
    };
  }

  unless (keys %missing or keys %unmet) {
    $self->log("all prereqs appear to be indexed");
    return;
  }

  if (keys %missing) {
    my @missing = sort keys %missing;
    $self->log("the following prereqs could not be found on CPAN: @missing");
  }

  if (keys %unmet) {
    for my $pkg (sort keys %unmet) {
      $self->log([
        "you required %s version %s but CPAN only has version %s",
        $pkg,
        "$unmet{$pkg}{required}",
        "$unmet{$pkg}{indexed}",
      ]);
    }
  }

  return if $self->zilla->chrome->prompt_yn(
    "release despite missing prereqs?",
    { default => 0 }
  );

  $self->log_fatal("aborting release due to apparently unindexed prereqs");
}

1;
