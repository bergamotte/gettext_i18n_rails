gem 'ruby_parser', '>= 3.7.1' # sync with gemspec
require 'ruby_parser'

gem 'sexp_processor'
require 'sexp_processor'

module RubyGettextExtractor
  extend self

  def parse(file, targets = [])  # :nodoc:
    parse_string(File.read(file), targets, file)
  end

  def parse_string(content, targets = [], file)
    syntax_tree = RubyParser.for_current_ruby.parse(content, file)

    processor = Extractor.new(targets)
    processor.require_empty = false
    processor.process(syntax_tree)

    processor.results
  end

  class Extractor < SexpProcessor
    attr_reader :results

    def initialize(targets)
      # TODO: At this point it's unclear what the targets arg does, need to
      #       investigate this further.
      @targets = {}
      @results = []

      targets.each do |a|
        k, _v = a
        # things go wrong if k already exists, but this
        # should not happen (according to the gettext doc)
        @targets[k] = a
        @results << a
      end

      super()
    end

    def extract_string(node)
      case node.first
      when :str
        node.last
      when :call
        type, recv, meth, args = node
        # node has to be in form of "string" + "other_string"
        return nil unless recv && meth == :+

        first_part  = extract_string(recv)
        second_part = extract_string(args)

        first_part && second_part ? first_part.to_s + second_part.to_s : nil
      else
        nil
      end
    end

    def extract_key_singular(args, separator)
      key = extract_string(args) if args.size == 2 || args.size == 4

      return nil unless key
      key.gsub("\n", '\n').gsub("\t", '\t').gsub("\0", '\0')
    end

    def extract_key_plural(args, separator)
      # this could be n_("aaa", "aaa plural", @retireitems.length)
      # s(s(:str, "aaa"),
      #   s(:str, "aaa plural"),
      #   s(:call, s(:ivar, :@retireitems), :length))
      # all strings arguments are extracted and joined with \004 or \000
      arguments = args[0..(-2)]

      res = []
      arguments.each do |a|
        next unless a.kind_of? Sexp
        str = extract_string(a)
        res << str if str
      end

      key = res.empty? ? nil : res.join(separator)

      return nil unless key
      key.gsub("\n", '\n').gsub("\t", '\t').gsub("\0", '\0')
    end

    def store_po_entry(po_entry)
      existing_entry = @results.find { |result| result.mergeable?(po_entry) }

      if existing_entry.nil?
        # TODO: Targets?
        @results << po_entry && return
      end

      # NOTE: POEntry#merge concats comments, which we don't want, so we'll
      #       manage the merge manually.
      existing_entry.references.concat(po_entry.references)
      comment = po_entry.extracted_comment
      unless !comment.nil? && !existing_entry.extracted_comment.nil? && existing_entry.extracted_comment.include?(comment)
        existing_entry.add_comment(comment)
      end
    end

    def store_key(key, args)
      if key
        res = @targets[key]

        unless res
          res = [key]
          @results << res
          @targets[key] = res
        end

        res << "#{args.file}:#{args.line}"
      end
    end

    def build_po_entry(type, id, context, file, line, comment = nil)
      entry = GetText::POEntry.new(type)
      entry.msgctxt = context unless context.nil?
      if type == :plural && id.kind_of?(Array)
        entry.msgid_plural = id[1]
        id = id[0]
      end
      entry.msgid = id
      entry.references = ["#{file}:#{line}"]
      entry.add_comment(comment) if comment
      entry
    end

    def gettext_simple_call(args)
      # args comes in 2 forms:
      #   s(s(:str, "Button Group Order:"))
      #   s(:str, "Button Group Order:")
      # normalizing:
      comment = args[1][1] if args[1]
      args = args.first if Sexp === args.sexp_type
      store_po_entry(build_po_entry(:normal, args[1], nil, args.file, args.line, comment))
    end

    def gettext_context_call(args)
      comment = args[2] ? args[2][1] : nil
      store_po_entry(build_po_entry(:msgctxt, args[1][1], args[0][1], args.file, args.line, comment))
    end

    def gettext_plural_call(args)
      comment = args[3] ? args[3][1] : nil
      # TODO: This doesn't support context yet (we'll use `np_` for that)
      store_po_entry(build_po_entry(:plural, [args[0][1], args[1][1]], nil, args.file, args.line, comment))
    end

    def process_call exp
      _call = exp.shift
      _recv = process exp.shift
      meth  = exp.shift

      case meth
      when :_, :N_, :s_
        gettext_simple_call(exp)
      when :p_, :pgettext
        gettext_context_call(exp)
      when :n_
        gettext_plural_call(exp)
      end

      until exp.empty? do
        process(exp.shift)
      end

      s()
    end
  end
end
