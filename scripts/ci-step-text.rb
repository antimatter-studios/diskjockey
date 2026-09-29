# ci-step-text.rb — what a workflow step actually runs, for the guards that
# read ci.yml (#211).
#
# The test tiers moved out of ci.yml into scripts/test-*.sh, so CI and
# `chore` run one command per tier instead of two that drift. A guard that
# read only a step's `run:` text would then see `scripts/test-app.sh` and
# nothing else, and every assertion about the suite's command — its flags, its
# floor, its signing — would fail, or worse, pass vacuously. So a step's text
# is its `run:` plus the body of every repository script that `run:` invokes,
# one level deep, with comment lines dropped from both: a comment that quotes
# a forbidden flag to explain why it is forbidden is not the command.
module CiStepText
  SCRIPT = %r{(?:\A|[\s;&|(])(?:bash\s+)?(scripts/[\w.-]+\.sh)\b}

  def self.code(text)
    text.to_s.lines.reject { |l| l.lstrip.start_with?("#") }.join
  end

  # repo: the checkout the step's relative script paths resolve against.
  def self.expanded(step, repo)
    run = code(step.is_a?(Hash) ? step["run"] : step)
    bodies = run.scan(SCRIPT).flatten.uniq.map do |path|
      file = File.join(repo, path)
      File.file?(file) ? "\n" + code(File.read(file, encoding: "UTF-8")) : ""
    end
    run + bodies.join
  end
end
