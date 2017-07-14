require 'spec_helper'

describe Gitlab::BackgroundMigration do
  describe '.queue' do
    it 'returns background migration worker queue' do
      expect(described_class.queue)
        .to eq BackgroundMigrationWorker.sidekiq_options['queue']
    end
  end

  describe '.steal' do
    context 'when there are enqueued jobs present' do
      let(:queue) do
        [double(args: ['Foo', [10, 20]], queue: described_class.queue)]
      end

      before do
        allow(Sidekiq::Queue).to receive(:new)
          .with(described_class.queue)
          .and_return(queue)
      end

      context 'when queue contains unprocessed jobs' do
        it 'steals jobs from a queue' do
          expect(queue[0]).to receive(:delete).and_return(true)

          expect(described_class).to receive(:perform).with('Foo', [10, 20])

          described_class.steal('Foo')
        end

        it 'does not steal job that has already been taken' do
          expect(queue[0]).to receive(:delete).and_return(false)

          expect(described_class).not_to receive(:perform).with('Foo', [10, 20])

          described_class.steal('Foo')
        end

        it 'does not steal jobs for a different migration' do
          expect(described_class).not_to receive(:perform)

          expect(queue[0]).not_to receive(:delete)

          described_class.steal('Bar')
        end
      end

      context 'when one of the jobs raises an error' do
        let(:migration) { spy(:migration) }

        let(:queue) do
          [double(args: ['Foo', [10, 20]], queue: described_class.queue),
           double(args: ['Foo', [20, 30]], queue: described_class.queue)]
        end

        before do
          stub_const("#{described_class}::Foo", migration)

          allow(migration).to receive(:perform).with(10, 20)
            .and_raise(StandardError, 'Migration error')

          allow(queue[0]).to receive(:delete).and_return(true)
          allow(queue[1]).to receive(:delete).and_return(true)
        end

        it 'recovers from an exceptions and continues' do
          expect(migration).to receive(:perform).twice
          expect { described_class.steal('Foo') }
            .to output(/Migration error/).to_stdout
        end
      end
    end

    context 'when there are scheduled jobs present', :sidekiq, :redis do
      it 'steals all jobs from the scheduled sets' do
        Sidekiq::Testing.disable! do
          BackgroundMigrationWorker.perform_in(10.minutes, 'Object')

          expect(Sidekiq::ScheduledSet.new).to be_one
          expect(described_class).to receive(:perform).with('Object', any_args)

          described_class.steal('Object')

          expect(Sidekiq::ScheduledSet.new).to be_none
        end
      end
    end

    context 'when there are enqueued and scheduled jobs present', :sidekiq, :redis do
      it 'steals from the scheduled sets queue first' do
        Sidekiq::Testing.disable! do
          expect(described_class).to receive(:perform)
            .with('Object', [1]).ordered
          expect(described_class).to receive(:perform)
            .with('Object', [2]).ordered

          BackgroundMigrationWorker.perform_async('Object', [2])
          BackgroundMigrationWorker.perform_in(10.minutes, 'Object', [1])

          described_class.steal('Object')
        end
      end
    end
  end

  describe '.perform' do
    it 'performs a background migration' do
      instance = double(:instance)
      klass = double(:klass, new: instance)

      expect(described_class).to receive(:const_get)
        .with('Foo')
        .and_return(klass)

      expect(instance).to receive(:perform).with(10, 20)

      described_class.perform('Foo', [10, 20])
    end
  end
end
