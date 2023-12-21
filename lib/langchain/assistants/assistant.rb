# frozen_string_literal: true

module Langchain
  class Assistant
    attr_reader :name, :llm, :thread, :instructions, :description

    attr_accessor :tools

    def initialize(
      name:,
      llm:,
      thread:,
      tools: [],
      instructions: nil,
      description: nil
    )
      # Check that the LLM class implements the `chat()` instance method
      raise ArgumentError, "LLM must implemented `chat()` method" unless llm.class.instance_methods(false).include?(:chat)

      @name = name
      @llm = llm
      @thread = thread
      @instructions = instructions
      @tools = tools
      @description = description
    end

    def add_message(text:, role: "user")
      # Add the message to the thread
      message = build_message(role: role, text: text)
      add_message_to_thread(message)
    end

    def run(auto_tool_execution: false)
      prompt = build_assistant_prompt(instructions: instructions, tools: tools)
      response = llm.chat(prompt: prompt)

      add_message(text: response.chat_completion, role: response.role)

      if auto_tool_execution
        run_tools(response.chat_completion)
      end

      thread.messages
    end

    # TODO: Need option to run tools automatically or not.
    def add_message_and_run(text:, auto_tool_execution: false)
      add_message(text: text)
      run(auto_tool_execution: auto_tool_execution)
    end

    def run_tools(completion)
      # Iterate over each tool and tool_input and submit tool output
      find_tool_invocations(completion).each_with_index do |tool_invocation, _index|
        tool_instance = tools.find { |t| t.name == tool_invocation[:tool_name] }
        output = tool_instance.execute(input: tool_invocation[:tool_input])

        submit_tool_output(tool_name: tool_invocation[:tool_name], output: output)

        prompt = build_assistant_prompt(instructions: instructions, tools: tools)
        response = llm.chat(prompt: prompt)

        add_message(text: response.chat_completion, role: response.role)
      end
    end

    def submit_tool_output(tool_name:, output:)
      message = build_message(role: "#{tool_name}_output", text: output)
      add_message_to_thread(message)
    end

    private

    # Does it make sense to introduce a state machine so that :requires_action is one of the states for example?
    def find_tool_invocations(completion)
      # TODO: Need better mechanism to find all tool calls that did not have tool output submitted
      # ...because there could be multiple tool calls.

      invoked_tools = []

      # Find all instances of tool invocations
      tools.each do |tool|
        completion.scan(/<#{tool.name}>(.*)<\/#{tool.name}>/m) # /./m - Any character (the m modifier enables multiline mode)
          .flatten
          .each do |tool_input|
            invoked_tools.push({tool_name: tool.name, tool_input: tool_input})
          end
      end

      invoked_tools
    end

    # TODO: Summarize or truncate the conversation when it exceeds the context window
    # Truncate the oldest messages when the context window is exceeded
    def build_chat_history
      thread
        .messages
        .map(&:to_s)
        .join("\n")
    end

    def build_message(role:, text:)
      Message.new(role: role, text: text)
    end

    def assistant_prompt(instructions:, tools:, chat_history:)
      prompts = []

      prompts.push(instructions_prompt(instructions: instructions)) if !instructions.empty?
      prompts.push(tools_prompt(tools: tools)) if tools.any?
      prompts.push(chat_history_prompt(chat_history: chat_history))

      prompts.join("\n\n")
    end

    def chat_history_prompt(chat_history:)
      Langchain::Prompt
        .load_from_path(file_path: "lib/langchain/assistants/prompts/chat_history_prompt.yaml")
        .format(chat_history: chat_history)
    end

    def instructions_prompt(instructions:)
      Langchain::Prompt
        .load_from_path(file_path: "lib/langchain/assistants/prompts/instructions_prompt.yaml")
        .format(instructions: instructions)
    end

    def tools_prompt(tools:)
      Langchain::Prompt
        .load_from_path(file_path: "lib/langchain/assistants/prompts/tools_prompt.yaml")
        .format(
          tools: tools
            .map(&:name_and_description)
            .join("\n")
        )
    end

    def build_assistant_prompt(instructions:, tools:)
      prompt = assistant_prompt(instructions: instructions, tools: tools, chat_history: build_chat_history)

      while begin
        # Return false to exit the while loop
        !llm.class.const_get(:LENGTH_VALIDATOR).validate_max_tokens!(
          prompt,
          llm.defaults[:chat_completion_model_name],
          {llm: llm}
        )
      # Rescue error if context window is exceeded and return true to continue the while loop
      rescue Langchain::Utils::TokenLength::TokenLimitExceeded
        true
      end
        # Check if the prompt exceeds the context window

        # Remove the oldest message from the thread
        thread.messages.shift
        prompt = assistant_prompt(instructions: instructions, tools: tools, chat_history: build_chat_history)
      end

      prompt
    end

    def add_message_to_thread(message)
      thread.messages << message
    end
  end
end
